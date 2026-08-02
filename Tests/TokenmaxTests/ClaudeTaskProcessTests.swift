import Foundation
import Testing

@testable import Tokenmax

/// The process plumbing, exercised against shell scripts rather than the real
/// CLI — so the parts that are hardest to get right are covered without any
/// test spending quota or touching a project.
@Suite("Claude task process handling")
struct ClaudeTaskProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(
        _ script: String,
        timeout: TimeInterval = 30,
        logURL: URL? = nil,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ClaudeTaskRunner.Result {
        let directory = scratch()
        return await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", script],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: logURL ?? directory.appendingPathComponent("run.log"),
            timeout: timeout,
            onProgress: onProgress
        )
    }

    // MARK: - The deadlock this runner exists to avoid

    @Test("A process that floods both pipes still completes", .timeLimit(.minutes(1)))
    func doesNotDeadlockOnLargeOutput() async {
        // The failure mode this replaces: reading stdout to EOF and *then*
        // stderr. The child fills the stderr pipe, blocks writing, and so never
        // closes stdout — both sides wait forever. 400KB each is far past the
        // 64KB pipe buffer, so a sequential reader would hang here and the test
        // would hit its time limit rather than fail cleanly.
        let script = """
        i=0
        while [ $i -lt 4000 ]; do
          echo "stdout line $i aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          echo "stderr line $i bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >&2
          i=$((i+1))
        done
        echo '{"type":"result","subtype":"success","is_error":false,"result":"flooded"}'
        """
        let result = await execute(script)
        #expect(result.status == .completed)
        #expect(result.resultText == "flooded")
    }

    // MARK: - Timeout

    @Test("A hung process is stopped at the runtime limit", .timeLimit(.minutes(1)))
    func timeoutStopsAHungProcess() async {
        let started = Date()
        let result = await execute("sleep 120", timeout: 2)

        #expect(result.status == .timedOut)
        #expect(result.errorMessage?.contains("runtime limit") == true)
        // The point of the concurrent drain: the old ordering blocked on
        // reading before the timeout clock was ever consulted, so the limit
        // could not fire at all.
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("A process that ignores SIGTERM is still killed", .timeLimit(.minutes(2)))
    func sigkillFollowsSigterm() async {
        // `trap ''` makes SIGTERM a no-op, so only the SIGKILL escalation can
        // end this. Without it the queue would wedge on one stubborn task.
        let result = await execute("trap '' TERM; sleep 120", timeout: 2)
        #expect(result.status == .timedOut)
    }

    // MARK: - Cancellation

    @Test("Cancelling the task stops the process", .timeLimit(.minutes(1)))
    func cancellationStopsTheProcess() async {
        let task = Task { await execute("sleep 120", timeout: 300) }

        // Let it get as far as spawning before pulling the rug.
        try? await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()

        let result = await task.value
        // Cancelled, never failed — a hand-stopped task must not trip
        // `pauseAfterFailure` and stop the rest of the queue.
        #expect(result.status == .cancelled)
        #expect(result.status.pausesQueue == false)
    }

    // MARK: - Output handling

    @Test("Output is streamed to the log file")
    func writesLogFile() async {
        let directory = scratch()
        let logURL = directory.appendingPathComponent("run.log")
        _ = await execute(
            "echo hello-stdout; echo hello-stderr >&2",
            logURL: logURL
        )

        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(contents.contains("hello-stdout"))
        #expect(contents.contains("hello-stderr"))
    }

    @Test("Progress is reported from the event stream")
    func reportsProgress() async {
        let collector = ProgressCollector()
        // Spaced out so each event lands in its own read. Delivered together
        // they coalesce — see the next test.
        _ = await execute(
            """
            echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep"}]}}'
            sleep 0.3
            echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}'
            sleep 0.3
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
            """,
            onProgress: { collector.append($0) }
        )
        let seen = collector.values
        #expect(seen.contains("Running Grep"))
        #expect(seen.contains("Running Edit"))
    }

    @Test("Only the newest event in a chunk is reported")
    func progressCoalescesWithinAChunk() async {
        // Deliberate: this drives a one-line "what is it doing now" label, not
        // a log. A burst of events arriving in a single read should leave that
        // label showing the newest activity rather than flickering through
        // every step — the run log keeps the full history.
        let collector = ProgressCollector()
        _ = await execute(
            """
            printf '%s\\n%s\\n' \\
              '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \\
              '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write"}]}}'
            """,
            onProgress: { collector.append($0) }
        )
        #expect(collector.values.last == "Running Write")
        #expect(!collector.values.contains("Running Read"))
    }

    @Test("A JSON object split across reads is still parsed")
    func handlesSplitLines() async {
        // Chunk boundaries fall wherever the pipe decides, so a result envelope
        // arriving in two pieces is the normal case, not an edge case.
        let script = """
        printf '{"type":"result","subtype":"success","is_error":false,'
        sleep 0.3
        printf '"result":"reassembled"}\\n'
        """
        let result = await execute(script)
        #expect(result.resultText == "reassembled")
    }

    @Test("The log file stops growing at its ceiling", .timeLimit(.minutes(1)))
    func logIsBounded() async {
        let directory = scratch()
        let logURL = directory.appendingPathComponent("big.log")
        // Comfortably past the 4MB ceiling.
        _ = await execute(
            "i=0; while [ $i -lt 60000 ]; do printf '%s\\n' " +
                "'padding padding padding padding padding padding padding padding padding'; i=$((i+1)); done",
            logURL: logURL
        )

        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        #expect(size <= ClaudeTaskRunner.maximumLogBytes + 4096)
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?.suffix(200) ?? ""
        #expect(tail.contains("output truncated"))
    }

    // MARK: - Exit handling

    @Test("A non-zero exit with no envelope reports stderr")
    func nonZeroExitWithoutEnvelope() async {
        let result = await execute("echo 'something went wrong' >&2; exit 3")
        #expect(result.status == .failed)
        #expect(result.exitCode == 3)
        #expect(result.errorMessage?.contains("something went wrong") == true)
    }

    @Test("Budget exhaustion is reported as its own outcome")
    func budgetOutcome() async {
        let result = await execute(
            "echo '{\"type\":\"result\",\"subtype\":\"error_max_budget\"," +
                "\"is_error\":true,\"result\":\"budget reached\"}'; exit 1"
        )
        #expect(result.status == .budgetExceeded)
    }

    @Test("A missing executable fails rather than hanging")
    func missingExecutable() async {
        let directory = scratch()
        let result = await ClaudeTaskRunner.execute(
            executable: URL(fileURLWithPath: "/definitely/not/a/binary"),
            arguments: [],
            directory: directory,
            environment: [:],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: 5,
            onProgress: { _ in }
        )
        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("Could not start") == true)
    }
}

/// Progress arrives on the runner's own queues, so collecting it needs a lock.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
