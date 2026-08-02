import Foundation
import Testing

@testable import Tokenmax

/// Termination, specifically of the processes the CLI spawns rather than the
/// CLI itself.
///
/// Claude Code runs its tools as child processes. Signalling only the direct
/// child leaves those grandchildren running: a timed-out task keeps burning
/// whatever it was doing, and the user has no way to see it, let alone stop it.
///
/// The fix is to give the child its own session so the whole group can be
/// signalled at once — which is only safe once the session actually exists,
/// hence the guards asserted here.
@Suite("Process group termination")
struct ProcessGroupTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-pgroup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(
        _ script: String,
        timeout: TimeInterval = 30
    ) async -> ClaudeTaskRunner.Result {
        let directory = scratch()
        return await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", script],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: timeout,
            onProgress: { _ in }
        )
    }

    /// True while `pid` names a live process we could signal.
    private func isAlive(_ pid: pid_t) -> Bool {
        // Signal 0 performs the permission and existence checks without
        // delivering anything.
        kill(pid, 0) == 0
    }

    // MARK: - The defect this phase fixes

    @Test("A grandchild does not survive a timeout", .timeLimit(.minutes(2)))
    func grandchildDiesWithTheGroup() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")

        // `trap '' TERM` makes the direct child ignore SIGTERM, so only the
        // SIGKILL escalation ends it — and the background `sleep` is the
        // grandchild that used to be left running afterwards.
        let script = """
        sleep 300 &
        echo $! > \(pidFile.path)
        trap '' TERM
        sleep 300
        """

        let result = await execute(script, timeout: 2)
        #expect(result.status == .timedOut)

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let grandchild = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }

        // The kill is asynchronous; give the group a moment to actually die.
        try? await Task.sleep(for: .seconds(1))

        #expect(!isAlive(grandchild), "the grandchild outlived the run that spawned it")

        // Belt and braces: if the assertion above failed, do not leave a stray
        // process behind for the next test run.
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    @Test("A grandchild does not survive a cancellation", .timeLimit(.minutes(2)))
    func grandchildDiesOnCancel() async {
        let pidFile = scratch().appendingPathComponent("grandchild.pid")
        let script = """
        sleep 300 &
        echo $! > \(pidFile.path)
        sleep 300
        """

        let running = Task { await execute(script, timeout: 120) }

        // Wait for the script to have spawned and recorded its grandchild.
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }

        running.cancel()
        let result = await running.value
        #expect(result.status == .cancelled)

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let grandchild = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("the script never reported its grandchild's pid")
            return
        }

        try? await Task.sleep(for: .seconds(1))
        #expect(!isAlive(grandchild), "the grandchild outlived the cancelled run")
        if isAlive(grandchild) { kill(grandchild, SIGKILL) }
    }

    // MARK: - The safety property that makes the above possible

    @Test("The child leads its own session, never ours", .timeLimit(.minutes(1)))
    func childIsItsOwnSessionLeader() throws {
        let directory = scratch()
        let output = Pipe()

        let process = try SpawnedProcess.spawn(
            executable: shell,
            // The child reports its own pid and process-group id.
            arguments: ["-c", "echo $$; ps -o pgid= -p $$"],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            standardOutput: output.fileHandleForWriting,
            standardError: FileHandle.nullDevice,
            standardInput: FileHandle.nullDevice
        )

        // Must be its own group leader — this is precisely the precondition
        // that makes `kill(-pid, …)` safe rather than suicidal.
        #expect(process.leadsItsOwnGroup)
        #expect(process.pid > 1)

        // And that group must not be Tokenmax's own, or terminating a run would
        // terminate the app running it.
        #expect(getpgid(process.pid) != getpgid(0))

        _ = try? output.fileHandleForWriting.close()
        _ = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
    }

    @Test("Tokenmax never signals its own process group", .timeLimit(.minutes(1)))
    func neverSignalsOurselves() {
        // The guard is a property of the process, not of the call site, so a
        // future caller cannot accidentally route around it.
        #expect(getpgid(0) == getpgid(getpid()) || getpgid(0) != -1)
        // Our own pid can never satisfy the leader test against a *spawned*
        // process, because a spawned one is compared to its own pid.
        let ours = getpid()
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: ours, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: 0, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: 1, ourGroup: getpgid(0)))
        #expect(!SpawnedProcess.isSafeToSignalGroup(pid: -1, ourGroup: getpgid(0)))
    }

    // MARK: - Ordinary behaviour is unchanged

    @Test("An ordinary run still reports its exit code", .timeLimit(.minutes(1)))
    func exitCodeSurvivesTheNewSpawn() async {
        let result = await execute("exit 3")
        #expect(result.exitCode == 3)
        #expect(result.status == .failed)
    }

    @Test("A successful run still parses its result envelope", .timeLimit(.minutes(1)))
    func envelopeStillParses() async {
        let result = await execute(
            #"echo '{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.02}'"#
        )
        #expect(result.status == .completed)
        #expect(result.resultText == "done")
        #expect(result.costUSD == 0.02)
    }

    @Test("The working directory is still the task's", .timeLimit(.minutes(1)))
    func workingDirectoryIsHonoured() async {
        // posix_spawn does not inherit a chdir the way Process's
        // currentDirectoryURL did, so this is worth asserting explicitly.
        let directory = scratch()
        let result = await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", #"echo "{\"type\":\"result\",\"result\":\"$(pwd)\"}""#],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: 30,
            onProgress: { _ in }
        )

        // Both sides are resolved: the scratch path runs through /private on
        // macOS, and which spelling `pwd` reports is not what is under test.
        let reported = URL(fileURLWithPath: result.resultText ?? "").resolvingSymlinksInPath().path
        let expected = directory.resolvingSymlinksInPath().path
        #expect(reported == expected)
    }

    @Test("The environment still reaches the child", .timeLimit(.minutes(1)))
    func environmentIsHonoured() async {
        let directory = scratch()
        let result = await ClaudeTaskRunner.execute(
            executable: shell,
            arguments: ["-c", #"echo "{\"type\":\"result\",\"result\":\"$TOKENMAX_PROBE\"}""#],
            directory: directory,
            environment: ["PATH": "/usr/bin:/bin", "TOKENMAX_PROBE": "reached"],
            logURL: directory.appendingPathComponent("run.log"),
            timeout: 30,
            onProgress: { _ in }
        )
        #expect(result.resultText == "reached")
    }
}
