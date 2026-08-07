import Foundation
import Testing

@testable import Tokenmax

/// Codex App Server plumbing exercised against a shell fixture. No Codex
/// process, account, network request, or paid turn is involved.
@Suite("Codex task process handling")
struct CodexTaskProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-codex-runner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func task(in directory: URL) -> TokenmaxTask {
        TokenmaxTask(
            title: "Fixture",
            prompt: "Test",
            providerID: CodexProvider.providerID,
            workingDirectory: directory.path
        )
    }

    private func serverScript(afterTurnStarted body: String) -> String {
        """
        IFS= read -r initialize
        echo '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r start
        echo '{"id":2,"result":{"thread":{"id":"thread-fixture"}}}'
        IFS= read -r turn
        echo '{"id":3,"result":{}}'
        \(body)
        """
    }

    private func execute(
        _ body: String,
        directory: URL,
        timeout: TimeInterval = 15
    ) -> ClaudeTaskRunner.Result {
        CodexTaskRunner.executeAppServer(
            executable: shell,
            arguments: ["-c", serverScript(afterTurnStarted: body)],
            task: task(in: directory),
            runID: UUID(),
            prompt: "Test",
            resuming: nil,
            onProgress: { _ in },
            timeout: timeout
        )
    }

    @Test("Flooding stderr cannot deadlock a Codex run", .timeLimit(.minutes(1)))
    func stderrIsDrained() {
        let directory = scratch()
        let result = execute(
            """
            i=0
            while [ $i -lt 6000 ]; do
              echo "stderr padding padding padding padding padding padding $i" >&2
              i=$((i+1))
            done
            echo '{"method":"item/agentMessage/delta","params":{"delta":"done"}}'
            echo '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
            """,
            directory: directory
        )

        #expect(result.status == .completed)
        #expect(result.resultText == "done")
    }

    @Test("Codex output and its raw log stop at their ceilings", .timeLimit(.minutes(1)))
    func outputIsBounded() {
        let directory = scratch()
        let runID = UUID()
        let script = serverScript(afterTurnStarted: """
        i=0
        while [ $i -lt 5000 ]; do
          echo '{"method":"item/agentMessage/delta","params":{"delta":"padding padding padding padding padding padding padding padding"}}'
          i=$((i+1))
        done
        head -c 5000000 /dev/zero >&2
        echo '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}'
        """)
        let result = CodexTaskRunner.executeAppServer(
            executable: shell,
            arguments: ["-c", script],
            task: task(in: directory),
            runID: runID,
            prompt: "Test",
            resuming: nil,
            onProgress: { _ in },
            timeout: 30
        )

        #expect(result.status == .completed)
        #expect((result.resultText?.count ?? 0) <= CodexTaskRunner.maximumResultCharacters + 64)
        #expect(result.resultText?.contains("Output truncated") == true)
        let log = FileLocations.runLogFile(runID: runID)
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        #expect(size <= CodexTaskRunner.maximumLogBytes + 4096)
    }

    /// There is no `turn/failed` notification in the App Server protocol, and
    /// listening for one meant a failed run reported that it failed and nothing
    /// else. The reason travels inside `turn/completed` as `turn.error`.
    @Test("A failed turn carries its reason out of turn/completed", .timeLimit(.minutes(1)))
    func failedTurnReportsWhy() {
        let directory = scratch()
        let result = execute(
            """
            echo '{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"1","items":[],"status":"failed","error":{"message":"Sandbox denied the write","additionalDetails":"path outside workspace"}}}}'
            """,
            directory: directory
        )

        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("Sandbox denied the write") == true)
        #expect(result.errorMessage?.contains("path outside workspace") == true)
    }

    /// `turn.error` is documented as populated only on failure, so a successful
    /// turn must not acquire an error message from a leftover empty object.
    @Test("A completed turn reports no error", .timeLimit(.minutes(1)))
    func completedTurnHasNoError() {
        let directory = scratch()
        let result = execute(
            """
            echo '{"method":"item/agentMessage/delta","params":{"delta":"All done."}}'
            echo '{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"1","items":[],"status":"completed"}}}'
            """,
            directory: directory
        )

        #expect(result.status == .completed)
        #expect(result.errorMessage == nil)
        #expect(result.resultText == "All done.")
    }

    @Test("A Codex grandchild does not survive the runtime limit", .timeLimit(.minutes(1)))
    func grandchildDiesOnTimeout() async {
        let directory = scratch()
        let pidFile = directory.appendingPathComponent("grandchild.pid")
        let result = execute(
            """
            trap '' TERM
            sleep 300 &
            echo $! > '\(pidFile.path)'
            sleep 300
            """,
            directory: directory,
            timeout: 1
        )
        #expect(result.status == .timedOut)

        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("the fixture never reported its grandchild")
            return
        }

        try? await Task.sleep(for: .seconds(CodexTaskRunner.terminationGrace + 1))
        #expect(kill(pid, 0) != 0, "the Codex grandchild outlived its timed-out run")
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
