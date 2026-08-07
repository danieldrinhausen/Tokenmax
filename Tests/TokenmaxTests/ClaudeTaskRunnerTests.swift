import Foundation
import Testing

@testable import Tokenmax

@Suite("Claude task runner")
struct ClaudeTaskRunnerTests {
    private func policy(
        files: Bool = true,
        shell: Bool = false,
        model: String = "sonnet",
        runtime: Int = 15,
        budget: Double = 0.50
    ) -> TaskExecutionPolicy {
        var policy = TaskExecutionPolicy()
        policy.allowFileChanges = files
        policy.allowShellCommands = shell
        policy.model = model
        policy.maximumRuntimeMinutes = runtime
        policy.maximumBudgetUSD = budget
        return policy
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Tool permissions

    @Test("Read-only access is always granted")
    func readAccessAlwaysGranted() {
        // A task that cannot read its own project cannot do anything useful.
        for files in [true, false] {
            for shell in [true, false] {
                let tools = policy(files: files, shell: shell).allowedTools
                #expect(tools.contains("Read(**)"))
                #expect(tools.contains("Glob(**)"))
                #expect(tools.contains("Grep(**)"))
            }
        }
    }

    @Test("Every file tool is confined to the working directory")
    func fileToolsAreScoped() {
        // Verified against the real CLI: a bare `Write` on the allowlist is
        // auto-approved for *any* path on the machine — a task pointed at one
        // project will happily write to /tmp. The `(**)` specifier is what
        // makes "edits files in the working directory" true rather than a
        // hopeful description, so an unscoped file tool must never ship.
        let tools = policy(files: true, shell: true).allowedTools
        for tool in tools where tool != "Bash" {
            #expect(tool.hasSuffix("(**)"), "\(tool) is not confined to the working directory")
        }
        #expect(!tools.contains("Write"))
        #expect(!tools.contains("Edit"))
        #expect(!tools.contains("Read"))
    }

    @Test("File changes and shell commands are separate opt-ins")
    func toolsFollowPolicy() {
        let readOnly = policy(files: false, shell: false).allowedTools
        #expect(!readOnly.contains("Edit(**)"))
        #expect(!readOnly.contains("Write(**)"))
        #expect(!readOnly.contains("Bash"))

        let safeCoding = policy(files: true, shell: false).allowedTools
        #expect(safeCoding.contains("Edit(**)"))
        #expect(safeCoding.contains("Write(**)"))
        #expect(!safeCoding.contains("Bash"))

        let shellCoding = policy(files: true, shell: true).allowedTools
        #expect(shellCoding.contains("Bash"))
    }

    @Test("The disclosure matches the policy it describes")
    func capabilitySummaryMatchesTools() {
        // The editor's panel is the only thing many users will read before
        // approving automation, so it must not drift from what is granted.
        let permissive = policy(files: true, shell: true)
        let summary = Dictionary(
            uniqueKeysWithValues: permissive.capabilitySummary.map { ($0.label, $0.granted) }
        )
        #expect(summary["Read files in the working directory"] == true)
        #expect(summary["Edit files in the working directory"] == permissive.allowedTools.contains("Edit(**)"))
        // No --mcp-config is ever passed, and --strict-mcp-config is always set.
        #expect(summary["Use MCP tools"] == false)
    }

    @Test("Shell access is disclosed as escaping the working directory")
    func shellIsDisclosedAsUnconfined() {
        // A shell can write anywhere whatever the file tools allow, so the
        // panel must stop promising a boundary that is no longer there.
        #expect(policy(files: true, shell: false).escapesWorkingDirectory == false)
        #expect(policy(files: true, shell: true).escapesWorkingDirectory)
    }

    // MARK: - Arguments

    @Test("Permissions are never bypassed")
    func neverBypassesPermissions() {
        let arguments = ClaudeTaskRunner.arguments(prompt: "Do it", policy: policy(shell: true))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--allow-dangerously-skip-permissions"))
        // Omitted on purpose: the default denies unlisted tools in print mode,
        // whereas a mode that could prompt would hang until the timeout.
        #expect(!arguments.contains("--permission-mode"))
    }

    @Test("The allowlist, model, and budget reach the CLI")
    func argumentsCarryPolicy() {
        let arguments = ClaudeTaskRunner.arguments(
            prompt: "Do it",
            policy: policy(files: true, shell: false, model: "haiku", budget: 0.25)
        )
        #expect(value(after: "--model", in: arguments) == "haiku")
        #expect(value(after: "--max-budget-usd", in: arguments) == "0.25")
        #expect(value(after: "--allowedTools", in: arguments) == "Read(**) Glob(**) Grep(**) Edit(**) Write(**)")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.last == "Do it")
    }

    /// The flag is built with `%.2f`, which is fine for cents but is exactly
    /// the kind of format string that quietly acquires a locale or an
    /// exponent. A three-figure budget is now reachable from the editor's
    /// "Other…" field, and `1e+02` would be rejected by the CLI.
    @Test("A large or odd spend limit reaches the CLI as plain dollars and cents")
    func largeBudgetIsFormattedPlainly() {
        #expect(
            value(after: "--max-budget-usd", in: ClaudeTaskRunner.arguments(
                prompt: "Do it", policy: policy(budget: 100)
            )) == "100.00"
        )
        #expect(
            value(after: "--max-budget-usd", in: ClaudeTaskRunner.arguments(
                prompt: "Do it", policy: policy(budget: 37.5)
            )) == "37.50"
        )
    }

    /// A task written before the thinking grade existed has to invoke the CLI
    /// exactly as it did, which means no flag at all rather than a default one.
    @Test("The effort flag is omitted entirely when unset")
    func effortOmittedWhenUnset() {
        var unset = policy()
        unset.effort = nil
        #expect(!ClaudeTaskRunner.arguments(prompt: "Do it", policy: unset).contains("--effort"))

        var empty = policy()
        empty.effort = ""
        #expect(!ClaudeTaskRunner.arguments(prompt: "Do it", policy: empty).contains("--effort"))
    }

    @Test("A chosen thinking grade reaches the CLI")
    func effortReachesCLI() {
        var chosen = policy()
        chosen.effort = "xhigh"
        let arguments = ClaudeTaskRunner.arguments(prompt: "Do it", policy: chosen)

        #expect(value(after: "--effort", in: arguments) == "xhigh")
        // The prompt stays the last positional argument.
        #expect(arguments.last == "Do it")
    }

    @Test("Conversations are saved, so a run can be replied to")
    func sessionsArePersisted() {
        // The opener passes this flag and should; a task must not. Without the
        // transcript on disk the reported session ID names nothing and every
        // run is a dead end.
        let arguments = ClaudeTaskRunner.arguments(prompt: "Do it", policy: policy())
        #expect(!arguments.contains("--no-session-persistence"))
        #expect(!arguments.contains("--resume"))
    }

    @Test("Resuming continues the original conversation")
    func resumeArguments() {
        let arguments = ClaudeTaskRunner.arguments(
            prompt: "Use the second option",
            policy: policy(),
            resuming: "session-abc"
        )
        #expect(value(after: "--resume", in: arguments) == "session-abc")
        // The reply is the prompt, and stays positional-last.
        #expect(arguments.last == "Use the second option")
        // Not forked: reusing the ID is what lets it serve as the thread key.
        #expect(!arguments.contains("--fork-session"))
    }

    @Test("A reply keeps the task's own limits")
    func replyKeepsPolicy() {
        // A follow-up is an ordinary run. If it dropped the caps, "just ask one
        // more thing" would become the way around them.
        let arguments = ClaudeTaskRunner.arguments(
            prompt: "And the tests?",
            policy: policy(files: false, shell: false, model: "haiku", budget: 0.25),
            resuming: "session-abc"
        )
        #expect(value(after: "--max-budget-usd", in: arguments) == "0.25")
        #expect(value(after: "--model", in: arguments) == "haiku")
        #expect(value(after: "--allowedTools", in: arguments) == "Read(**) Glob(**) Grep(**)")
    }

    @Test("stream-json is requested with the verbose flag it requires")
    func streamingArguments() {
        let arguments = ClaudeTaskRunner.arguments(prompt: "x", policy: policy())
        #expect(value(after: "--output-format", in: arguments) == "stream-json")
        #expect(arguments.contains("--verbose"))
    }

    @Test("Project settings are left alone, unlike the opener")
    func keepsSettingSources() {
        // The opener clears these because it wants nothing; a real task needs
        // CLAUDE.md and project settings to do useful work.
        let arguments = ClaudeTaskRunner.arguments(prompt: "x", policy: policy())
        #expect(!arguments.contains("--setting-sources"))
    }

    // MARK: - Environment

    @Test("API-key variables are stripped, and the rest survives")
    func environmentStripsBillingVariables() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "ANTHROPIC_API_KEY": "sk-secret",
            "ANTHROPIC_AUTH_TOKEN": "token",
            "ANTHROPIC_BASE_URL": "https://example.com",
            "NODE_ENV": "development",
            "GIT_AUTHOR_NAME": "Someone",
        ]
        let environment = ClaudeTaskRunner.environment(from: parent)

        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)

        // A denylist, unlike the opener's allowlist, on purpose: a real task
        // needs the project's toolchain on PATH.
        #expect(environment["NODE_ENV"] == "development")
        #expect(environment["GIT_AUTHOR_NAME"] == "Someone")
        #expect(environment["PATH"] == "/usr/bin")
    }

    @Test("A missing PATH is filled in rather than inherited empty")
    func environmentSuppliesPath() {
        let environment = ClaudeTaskRunner.environment(from: [:])
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
    }

    // MARK: - Stream parsing

    @Test("Tool use is preferred over prose for the progress line")
    func progressPrefersToolNames() {
        let line = """
        {"type":"assistant","message":{"content":[\
        {"type":"text","text":"Let me look at that"},\
        {"type":"tool_use","name":"Edit","input":{}}]}}
        """
        #expect(ClaudeTaskRunner.progressLine(fromJSONLine: line) == "Running Edit")
    }

    @Test("Text is used when there is no tool call")
    func progressFallsBackToText() {
        let line = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Working on the parser"}]}}
        """
        #expect(ClaudeTaskRunner.progressLine(fromJSONLine: line) == "Working on the parser")
    }

    @Test("Noise and malformed lines produce no progress")
    func progressIgnoresNoise() {
        #expect(ClaudeTaskRunner.progressLine(fromJSONLine: "not json") == nil)
        #expect(ClaudeTaskRunner.progressLine(fromJSONLine: "{\"type\":\"stream_event\"}") == nil)
        #expect(ClaudeTaskRunner.progressLine(fromJSONLine: "") == nil)
    }

    @Test("Only the result line is treated as the result envelope")
    func envelopeParsing() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":false,"result":"Done",\
        "session_id":"abc","total_cost_usd":0.0123}
        """
        let envelope = try #require(ClaudeTaskRunner.resultEnvelope(fromJSONLine: line))
        #expect(envelope.result == "Done")
        #expect(envelope.sessionId == "abc")
        #expect(envelope.totalCostUsd == 0.0123)

        #expect(ClaudeTaskRunner.resultEnvelope(fromJSONLine: "{\"type\":\"assistant\"}") == nil)
    }

    // MARK: - Exit classification

    @Test("A clean result is completed, with its cost recorded")
    func classifySuccess() {
        let envelope = ClaudeTaskRunner.resultEnvelope(fromJSONLine: """
        {"type":"result","subtype":"success","is_error":false,"result":"Done","total_cost_usd":0.02}
        """)
        let result = ClaudeTaskRunner.classify(exitCode: 0, envelope: envelope, stderr: "")
        #expect(result.status == .completed)
        #expect(result.costUSD == 0.02)
        #expect(result.errorMessage == nil)
    }

    @Test("Budget exhaustion is not a failure")
    func classifyBudget() {
        // Reporting it as `.failed` would also trip pauseAfterFailure and stop
        // the queue over a limit that worked exactly as configured.
        let envelope = ClaudeTaskRunner.resultEnvelope(fromJSONLine: """
        {"type":"result","subtype":"error_max_budget","is_error":true,"result":"Budget reached"}
        """)
        let result = ClaudeTaskRunner.classify(exitCode: 1, envelope: envelope, stderr: "")
        #expect(result.status == .budgetExceeded)
        #expect(result.status.pausesQueue == false)
    }

    @Test("An error envelope is a failure")
    func classifyError() {
        let envelope = ClaudeTaskRunner.resultEnvelope(fromJSONLine: """
        {"type":"result","subtype":"error","is_error":true,"result":"Something broke"}
        """)
        let result = ClaudeTaskRunner.classify(exitCode: 1, envelope: envelope, stderr: "")
        #expect(result.status == .failed)
        #expect(result.errorMessage == "Something broke")
    }

    @Test("A non-zero exit with a clean envelope still fails")
    func classifyNonZeroExit() {
        let envelope = ClaudeTaskRunner.resultEnvelope(fromJSONLine: """
        {"type":"result","subtype":"success","is_error":false,"result":"Partial"}
        """)
        let result = ClaudeTaskRunner.classify(exitCode: 3, envelope: envelope, stderr: "boom")
        #expect(result.status == .failed)
    }

    @Test("No envelope at all reports the stderr tail")
    func classifyMissingEnvelope() {
        let result = ClaudeTaskRunner.classify(exitCode: 127, envelope: nil, stderr: "command not found")
        #expect(result.status == .failed)
        #expect(result.errorMessage?.contains("command not found") == true)
    }

    @Test("With no stderr the exit code is the explanation")
    func classifyFallsBackToExitCode() {
        let result = ClaudeTaskRunner.classify(exitCode: 9, envelope: nil, stderr: "   ")
        #expect(result.errorMessage?.contains("exit code 9") == true)
    }

    // MARK: - CLI drift

    @Test("A rejected flag is told apart from a failed task")
    func classifyRejectedFlag() {
        // The wording varies between CLI versions and argument parsers, so the
        // detector has to cope with more than one phrasing.
        let phrasings = [
            "error: unknown option '--max-budget-usd'",
            "Unrecognized option --max-budget-usd",
            "invalid option: --max-budget-usd",
        ]
        for stderr in phrasings {
            let result = ClaudeTaskRunner.classify(exitCode: 1, envelope: nil, stderr: stderr)
            #expect(result.status == .incompatibleCLI, "not detected: \(stderr)")
            #expect(result.errorMessage?.contains("--max-budget-usd") == true)
        }
    }

    @Test("A rejected flag stops the queue rather than burning through it")
    func rejectedFlagPausesQueue() {
        // Every later task would fail the same way, so this is the one outcome
        // where pausing is necessary rather than merely defensible.
        #expect(TaskRunStatus.incompatibleCLI.pausesQueue)
    }

    @Test("An ordinary failure is not mistaken for CLI drift")
    func ordinaryFailureIsNotDrift() {
        // "option" appears in plenty of normal output; only the rejection
        // phrasings should trip the detector.
        let result = ClaudeTaskRunner.classify(
            exitCode: 1,
            envelope: nil,
            stderr: "The --model option was set to sonnet but the test suite failed"
        )
        #expect(result.status == .failed)
    }

    // MARK: - Stopped runs

    @Test("A timed-out run reports the CLI's stderr instead of swallowing it")
    func timeoutKeepsStderr() {
        // A killed run has no result envelope, so stderr is the only evidence
        // it leaves behind. Reporting a fixed sentence instead made every
        // timeout undiagnosable.
        let message = ClaudeTaskRunner.stoppedExplanation(
            .timedOut,
            stderr: "Error: could not reach the credential store",
            bytesWritten: 4096
        )
        #expect(message.contains("exceeded its runtime limit"))
        #expect(message.contains("could not reach the credential store"))
    }

    @Test("A timeout with no output at all says so")
    func timeoutWithNoOutputIsCalledOut() {
        // Zero bytes means the CLI never started work — a different problem
        // from a task that ran long, and the user cannot tell them apart
        // without being told.
        let message = ClaudeTaskRunner.stoppedExplanation(
            .timedOut, stderr: "", bytesWritten: 0
        )
        #expect(message.contains("no output at all"))
    }

    @Test("A timeout that produced output does not claim it produced none")
    func timeoutWithOutputStaysQuiet() {
        let message = ClaudeTaskRunner.stoppedExplanation(
            .timedOut, stderr: "", bytesWritten: 1
        )
        #expect(!message.contains("no output at all"))
    }

    @Test("A cancelled run is not described as a timeout")
    func cancelledIsNotATimeout() {
        let message = ClaudeTaskRunner.stoppedExplanation(
            .cancelled, stderr: "", bytesWritten: 0
        )
        #expect(!message.contains("runtime limit"))
        #expect(!message.contains("no output at all"))
    }

    @Test("A clean exit is never treated as drift")
    func successIsNotDrift() {
        let envelope = ClaudeTaskRunner.resultEnvelope(fromJSONLine: """
        {"type":"result","subtype":"success","is_error":false,"result":"Done"}
        """)
        let result = ClaudeTaskRunner.classify(exitCode: 0, envelope: envelope, stderr: "unknown option --x")
        #expect(result.status == .completed)
    }
}
