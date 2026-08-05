import Foundation

/// Runs the one minimal Claude Code request that opens a new five-hour window.
///
/// Everything here is shaped by a single goal: the request must be the smallest
/// possible thing that still counts as usage. No tools, no MCP servers, no
/// settings files, no project context, no transcript left behind.
enum ClaudeOpenerRunner {
    /// The prompt. Short, unambiguous, and gives the model no reason to think.
    static let prompt = "Reply with the two characters OK and nothing else."

    /// Long enough for a cold CLI start on a busy Mac, short enough that a hung
    /// process cannot pin the opener open indefinitely.
    static let timeout: TimeInterval = 90

    struct Result: Sendable, Equatable {
        var succeeded: Bool
        var text: String?
        var sessionID: String?
        var costUSD: Double?
        var errorMessage: String?
    }

    /// The `--print` result envelope. Only the fields worth recording.
    private struct ResultEnvelope: Decodable {
        let isError: Bool?
        let result: String?
        let sessionId: String?
        let totalCostUsd: Double?

        private enum CodingKeys: String, CodingKey {
            case isError = "is_error"
            case result
            case sessionId = "session_id"
            case totalCostUsd = "total_cost_usd"
        }
    }

    static func arguments(model: String, effort: String? = nil) -> [String] {
        var arguments = [
            "--print",
            "--model", model,
        ]
        if let effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        arguments += [
            "--output-format", "json",
            // "" disables every built-in tool. The opener must never touch the
            // user's machine — it exists to consume a token, not to do work.
            "--tools", "",
            // No --mcp-config is passed, so "strict" means no MCP servers at all.
            "--strict-mcp-config",
            "--disable-slash-commands",
            // No user/project/local settings: no hooks, and no `env` block that
            // could reintroduce an API key behind our back.
            "--setting-sources", "",
            // Nothing to resume, nothing to clean up.
            "--no-session-persistence",
            // With no tools this should never trigger, but a prompt in a
            // headless process would hang until the timeout.
            "--permission-mode", "manual",
            prompt,
        ]
        return arguments
    }

    /// Deliberately *not* the parent environment.
    ///
    /// An inherited `ANTHROPIC_API_KEY` would silently move the run onto
    /// pay-as-you-go billing — the exact charge this feature is built to avoid.
    /// A menubar app's environment is already minimal, so this mostly guards
    /// against a future launch path (a LaunchAgent, a debugger, a shell) that
    /// hands us a richer one. An allowlist stays safe as new variables appear;
    /// a denylist would not.
    static func environment(from parent: [String: String]) -> [String: String] {
        let allowed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR"]
        var result = parent.filter { allowed.contains($0.key) }
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        return result
    }

    static func parse(stdout: String) -> Result {
        guard let data = stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResultEnvelope.self, from: data)
        else {
            return Result(
                succeeded: false,
                text: nil,
                sessionID: nil,
                costUSD: nil,
                errorMessage: "Could not parse the CLI response."
            )
        }

        let ok = envelope.isError != true
        return Result(
            succeeded: ok,
            text: envelope.result,
            sessionID: envelope.sessionId,
            costUSD: envelope.totalCostUsd,
            errorMessage: ok ? nil : (envelope.result ?? "The CLI reported an error.")
        )
    }

    /// Spawns the CLI in a fresh empty directory and returns what it said.
    ///
    /// Blocking, so callers run it off the main actor.
    static func run(model: String, effort: String? = nil) -> Result {
        guard let cli = ClaudeCLIClient.locate() else {
            return Result(
                succeeded: false, text: nil, sessionID: nil, costUSD: nil,
                errorMessage: "The claude CLI could not be found."
            )
        }

        // An empty directory means no CLAUDE.md to discover and no repository to
        // describe — the request stays as small as it looks.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-opener-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            return Result(
                succeeded: false, text: nil, sessionID: nil, costUSD: nil,
                errorMessage: "Could not create a working directory: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = cli
        process.arguments = arguments(model: model, effort: effort)
        process.currentDirectoryURL = workingDirectory
        process.environment = environment(from: ProcessInfo.processInfo.environment)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Without this the CLI can block forever waiting on a prompt from stdin.
        process.standardInput = FileHandle.nullDevice

        Log.shared.write("opener: running \(cli.path) --model \(model)")

        do {
            try process.run()
        } catch {
            return Result(
                succeeded: false, text: nil, sessionID: nil, costUSD: nil,
                errorMessage: "Could not start the CLI: \(error.localizedDescription)"
            )
        }

        // Drain both pipes concurrently. Reading one pipe to EOF before the
        // other can deadlock the CLI when stderr fills while it is producing
        // stdout. It also means the timeout below is actually enforceable.
        let group = DispatchGroup()
        let outputBox = ClaudeOpenerOutputBox()
        let errorBox = ClaudeOpenerOutputBox()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            group.wait()
            Log.shared.write("opener: timed out after \(Int(timeout))s")
            return Result(
                succeeded: false, text: nil, sessionID: nil, costUSD: nil,
                errorMessage: "The CLI did not answer within \(Int(timeout))s."
            )
        }
        process.waitUntilExit()
        group.wait()

        let stdout = String(data: outputBox.value, encoding: .utf8) ?? ""
        let stderr = String(data: errorBox.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.isEmpty ? "exit code \(process.terminationStatus)" : stderr
            Log.shared.write("opener: CLI failed (\(detail))")
            return Result(
                succeeded: false, text: nil, sessionID: nil, costUSD: nil,
                errorMessage: "The CLI failed: \(detail)"
            )
        }

        var result = parse(stdout: stdout)
        if !result.succeeded, result.errorMessage == nil, !stderr.isEmpty {
            result.errorMessage = stderr
        }
        return result
    }
}


/// Synchronizes the result of a pipe-draining worker without capturing a mutable
/// local variable in concurrently executing code.
private final class ClaudeOpenerOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var value: Data {
        get {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock(); stored = newValue; lock.unlock()
        }
    }
}
