import Foundation

/// Runs a real queued task through the Claude Code CLI.
///
/// Deliberately **not** built on `ClaudeOpenerRunner`. The opener's entire
/// purpose is to be the smallest thing that counts as usage: no tools, no
/// settings, no project, an empty temporary directory. A queued task needs the
/// opposite — the project's files, its `CLAUDE.md`, its git context, and enough
/// tools to do work. The two share a CLI and nothing else, and merging them
/// would mean loosening the opener to match.
enum ClaudeTaskRunner {
    /// How long to wait after SIGTERM before SIGKILL. Long enough for the CLI
    /// to finish an in-flight write, short enough not to hang the queue.
    static let terminationGrace: TimeInterval = 10

    /// A run whose streams never reach EOF after the process exits resolves
    /// anyway after this long, rather than hanging the queue forever.
    static let drainGrace: TimeInterval = 3

    /// Beyond this the log stops growing and gets a truncation marker. A
    /// runaway task must not fill the disk.
    static let maximumLogBytes = 4 * 1024 * 1024

    /// Kept for the error message; the log file has everything.
    static let maximumStderrBytes = 16 * 1024

    struct Result: Sendable, Equatable {
        var status: TaskRunStatus
        var exitCode: Int32?
        var resultText: String?
        var sessionID: String?
        var costUSD: Double?
        var errorMessage: String?
    }

    /// The `--output-format stream-json` result envelope, which is the last line
    /// of the stream. Every field optional so a shape change upstream degrades
    /// to "unknown" rather than throwing away a run that really happened.
    struct ResultEnvelope: Decodable, Sendable {
        var type: String?
        var subtype: String?
        var isError: Bool?
        var result: String?
        var sessionId: String?
        var totalCostUsd: Double?
        var numTurns: Int?

        private enum CodingKeys: String, CodingKey {
            case type, subtype, result
            case isError = "is_error"
            case sessionId = "session_id"
            case totalCostUsd = "total_cost_usd"
            case numTurns = "num_turns"
        }
    }

    // MARK: - Arguments

    /// Never `--dangerously-skip-permissions`.
    ///
    /// `--permission-mode` is deliberately omitted so the default applies: in
    /// `--print` mode anything outside `--allowedTools` is denied outright
    /// rather than prompting, which is exactly what an unattended run wants. A
    /// mode that could prompt would hang the process until the timeout.
    ///
    /// `--setting-sources` is *not* cleared, unlike the opener: a real task
    /// needs the project's `CLAUDE.md` and settings to do anything useful.
    /// `--no-session-persistence` is deliberately **not** passed, unlike the
    /// opener. The opener has nothing worth keeping; a task does. Persisting the
    /// transcript is what makes `resuming` possible at all — without it the CLI
    /// discards the conversation the moment the process exits, and the
    /// `session_id` it reports back names something that no longer exists.
    static func arguments(
        prompt: String,
        policy: TaskExecutionPolicy,
        resuming sessionID: String? = nil
    ) -> [String] {
        var arguments = [
            "--print",
            "--model", policy.model,
        ]
        // Omitted entirely when unset, rather than sent as a default: a task
        // written before this existed must invoke the CLI exactly as it did.
        if let effort = policy.effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        arguments += [
            "--output-format", "stream-json",
            // stream-json requires it in print mode.
            "--verbose",
            // Enforced by the CLI itself, which makes it the one limit that
            // still holds if Tokenmax is killed mid-run. Note that it is a
            // *per-process* cap, so each turn of a thread gets its own.
            "--max-budget-usd", String(format: "%.2f", policy.maximumBudgetUSD),
            "--allowedTools", policy.allowedTools.joined(separator: " "),
            // No --mcp-config is passed, so "strict" means no MCP servers.
            "--strict-mcp-config",
        ]

        // Without --fork-session the resumed conversation keeps its original
        // ID, which is what lets `sessionID` serve as the thread key.
        if let sessionID {
            arguments += ["--resume", sessionID]
        }

        arguments.append(prompt)
        return arguments
    }

    /// The inverse of `ClaudeOpenerRunner.environment`, and deliberately so.
    ///
    /// The opener allowlists a handful of variables because it needs nothing;
    /// a real task needs a working `PATH` for git, node, and whatever else the
    /// project's tooling reaches for, so it inherits the environment and strips
    /// the specific variables that would move the run onto pay-as-you-go
    /// billing. An allowlist here would break real projects in ways that are
    /// tedious to diagnose; a denylist is the right shape for *this* runner
    /// even though it is the wrong shape for the opener.
    ///
    /// If you are here to make the two consistent: don't. They differ on purpose.
    static func environment(from parent: [String: String]) -> [String: String] {
        let denied = [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_MODEL",
        ]
        var result = parent.filter { !denied.contains($0.key) }
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        return result
    }

    // MARK: - Stream parsing

    /// A human-readable progress line from one NDJSON event, or nil for events
    /// that say nothing worth showing.
    static func progressLine(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String
        else { return nil }

        switch type {
        case "system":
            return root["subtype"] as? String == "init" ? "Starting…" : nil

        case "assistant":
            guard let message = root["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return nil }

            // A tool name is the most informative thing in an assistant turn:
            // "Editing" tells the user more than the first words of prose.
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { return "Running \(name)" }
            }
            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return String(trimmed.prefix(90)) }
                }
            }
            return nil

        case "result":
            return "Finishing up…"

        default:
            return nil
        }
    }

    static func resultEnvelope(fromJSONLine line: String) -> ResultEnvelope? {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResultEnvelope.self, from: data),
              envelope.type == "result"
        else { return nil }
        return envelope
    }

    /// Whether stderr says the CLI rejected the command line itself, rather
    /// than the task going wrong.
    ///
    /// Tokenmax passes about a dozen flags it does not own, and a CLI release
    /// that renames one turns every run into an identical instant failure. That
    /// is worth telling apart from a task that genuinely failed: the fix is to
    /// update Tokenmax, not to debug the prompt, and no amount of retrying will
    /// help. Matched on stderr because the CLI exits before emitting a result
    /// envelope, so there is nothing else to read.
    static func rejectedInvocation(stderr: String) -> String? {
        let lowered = stderr.lowercased()
        let signals = [
            "unknown option",
            "unknown argument",
            "unrecognized option",
            "invalid option",
            "unknown flag",
            "unknown command",
        ]
        guard signals.contains(where: lowered.contains) else { return nil }

        // Pull the offending flag out of the message so the error names it.
        // Falls back to the raw stderr tail when the shape is unfamiliar.
        let flag = stderr
            .split(whereSeparator: { " \n\t'\"".contains($0) })
            .first { $0.hasPrefix("--") }
        return flag.map(String.init)
    }

    /// What to tell the user about a run Tokenmax killed.
    ///
    /// A killed run is the hardest kind to diagnose: there is no result envelope
    /// to read, and if the CLI hung before writing anything to stdout the
    /// transcript is empty too. The stderr tail is then the *only* evidence that
    /// the run left behind, and reporting a fixed sentence instead of it — as
    /// this did — leaves the user with something they cannot act on.
    ///
    /// The byte count is included for the same reason. "Produced no output at
    /// all" and "was working and ran long" are different problems with different
    /// fixes, and only this number tells them apart.
    static func stoppedExplanation(
        _ reason: TaskRunStatus,
        stderr: String,
        bytesWritten: Int
    ) -> String {
        var message = reason == .timedOut
            ? "The task exceeded its runtime limit and was stopped."
            : "Stopped."

        if reason == .timedOut, bytesWritten == 0 {
            message += " It produced no output at all before being stopped, "
                + "which usually means the CLI never started work rather than "
                + "that the task was too large."
        }

        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            message += "\n\n\(String(tail.suffix(400)))"
        }
        return message
    }

    /// Turns an exit code and the final envelope into an outcome.
    ///
    /// Budget exhaustion is separated from failure on purpose: the task did not
    /// go wrong, it spent the allowance the user gave it, and the partial work
    /// is usually still worth looking at. Reporting it as "failed" would also
    /// trip `pauseAfterFailure` and stop the queue over a working limit.
    static func classify(exitCode: Int32, envelope: ResultEnvelope?, stderr: String) -> Result {
        // Checked before the envelope: a rejected command line produces no
        // envelope at all, and the generic "exited without a result" message
        // that would otherwise apply buries the one fact that matters.
        if exitCode != 0, let flag = rejectedInvocation(stderr: stderr) {
            return Result(
                status: .incompatibleCLI,
                exitCode: exitCode,
                resultText: nil,
                sessionID: nil,
                costUSD: nil,
                errorMessage: """
                    The Claude CLI rejected \(flag). This is a Tokenmax problem, \
                    not a problem with the task — the CLI has changed its options. \
                    Run `make doctor` to see which flags moved.
                    """
            )
        }
        if let envelope {
            let subtype = envelope.subtype?.lowercased() ?? ""
            let text = envelope.result ?? ""
            if subtype.contains("budget") || (envelope.isError == true && text.lowercased().contains("budget")) {
                return Result(
                    status: .budgetExceeded,
                    exitCode: exitCode,
                    resultText: envelope.result,
                    sessionID: envelope.sessionId,
                    costUSD: envelope.totalCostUsd,
                    errorMessage: "Stopped at the budget limit for this task."
                )
            }

            let failed = envelope.isError == true || exitCode != 0
            return Result(
                status: failed ? .failed : .completed,
                exitCode: exitCode,
                resultText: envelope.result,
                sessionID: envelope.sessionId,
                costUSD: envelope.totalCostUsd,
                errorMessage: failed ? (envelope.result ?? stderrOrCode(stderr, exitCode)) : nil
            )
        }

        // No envelope at all: the CLI died before finishing its stream.
        return Result(
            status: .failed,
            exitCode: exitCode,
            resultText: nil,
            sessionID: nil,
            costUSD: nil,
            errorMessage: "The CLI exited without a result (\(stderrOrCode(stderr, exitCode)))."
        )
    }

    private static func stderrOrCode(_ stderr: String, _ exitCode: Int32) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit code \(exitCode)" : String(trimmed.suffix(400))
    }

    // MARK: - Running

    /// Spawns the CLI and streams its output to `FileLocations.runLogFile(runID:)`.
    ///
    /// Cancellable through ordinary task cancellation: cancelling the `Task`
    /// that calls this terminates the process and resolves as `.cancelled`.
    ///
    /// `prompt` overrides the task's own prompt, and `resuming` continues an
    /// earlier conversation — together they make a follow-up reply, which is
    /// otherwise an ordinary run: same policy, same caps, same log-per-run.
    static func run(
        task: TokenmaxTask,
        runID: UUID,
        prompt: String? = nil,
        resuming sessionID: String? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result {
        guard let cli = ClaudeCLIClient.locate() else {
            return Result(
                status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil,
                errorMessage: "The claude CLI could not be found."
            )
        }
        guard let directory = task.expandedWorkingDirectory, task.workingDirectoryExists else {
            return Result(
                status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil,
                errorMessage: "Working directory not found: \(task.workingDirectory ?? "(none)")"
            )
        }
        // The last line of defence, and the one that also covers manual runs.
        // Spawning into a directory macOS will not let us open does not fail —
        // it *hangs*, inside the CLI's first read, until the runtime limit kills
        // it. Refusing here costs a syscall and turns fifteen wasted minutes
        // into an instant, actionable message.
        guard task.workingDirectoryReadable else {
            return Result(
                status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil,
                errorMessage: """
                    macOS is blocking access to \(task.workingDirectory ?? "the working directory"). \
                    Open the task and use Grant Access, or allow Tokenmax under System Settings → \
                    Privacy & Security → Files and Folders.
                    """
            )
        }

        let policy = task.autoRun
        let text = prompt ?? task.prompt

        Log.shared.write(
            "autorun: running \(task.title) in \(directory.path) "
                + (sessionID.map { "(resuming \($0)) " } ?? "")
                + "(model=\(policy.model), effort=\(policy.effort ?? "default"), "
                + "tools=\(policy.allowedTools.joined(separator: ",")), "
                + "cap=\(policy.maximumRuntimeMinutes)m, budget=$\(policy.maximumBudgetUSD))"
        )

        return await execute(
            executable: cli,
            arguments: arguments(prompt: text, policy: policy, resuming: sessionID),
            directory: directory,
            environment: environment(from: ProcessInfo.processInfo.environment),
            logURL: FileLocations.runLogFile(runID: runID),
            timeout: Double(policy.maximumRuntimeMinutes) * 60,
            onProgress: onProgress
        )
    }

    /// The process plumbing, with no knowledge of tasks or the Claude CLI.
    ///
    /// Split out so the parts that are genuinely hard to get right — draining
    /// two pipes without deadlocking, killing a process that will not stop,
    /// resuming a continuation exactly once — can be tested against ordinary
    /// shell scripts instead of against real, quota-spending runs.
    static func execute(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        logURL: URL,
        timeout: TimeInterval,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> Result {
        let box = RunBox(logURL: logURL, timeout: timeout, onProgress: onProgress)

        let outputPipe = Pipe()
        let errorPipe = Pipe()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                box.attach(continuation: continuation)

                // Both streams are drained concurrently through their own
                // handlers. Reading one to EOF and *then* the other — as
                // `ClaudeOpenerRunner` does — deadlocks as soon as the child
                // fills the pipe we are not reading: it blocks writing, so it
                // never closes the pipe we are waiting on. Survivable for the
                // opener, which emits almost nothing; fatal for a real task.
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        box.streamFinished(.stdout)
                    } else {
                        box.appendStdout(data)
                    }
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        box.streamFinished(.stderr)
                    } else {
                        box.appendStderr(data)
                    }
                }

                do {
                    let process = try SpawnedProcess.spawn(
                        executable: executable,
                        arguments: arguments,
                        directory: directory,
                        environment: environment,
                        standardOutput: outputPipe.fileHandleForWriting,
                        standardError: errorPipe.fileHandleForWriting,
                        // Without this the CLI can block forever waiting on stdin.
                        standardInput: FileHandle.nullDevice
                    )

                    // Essential, and the one thing `Process` did for us. The
                    // child holds its own copies of these descriptors now; if
                    // the parent keeps its copies open, the read ends never see
                    // EOF after the child exits and every run hangs until the
                    // drain grace expires.
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()

                    box.attach(process: process)
                    process.onExit { code in box.processExited(code: code) }
                    box.startTimeoutClock()
                } catch {
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    box.failToStart("Could not start the CLI: \(error.localizedDescription)")
                }
            }
        } onCancel: {
            box.stop(as: .cancelled)
        }
    }
}

/// The mutable half of a run, behind a lock.
///
/// Everything here is touched from at least three places at once — two
/// readability handlers on their own queues, the process's termination handler,
/// a timeout timer, and possibly a cancellation from the main actor — so all of
/// it is guarded and the continuation is resumed exactly once.
private final class RunBox: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let logURL: URL
    private let timeout: TimeInterval
    private let onProgress: @Sendable (String) -> Void

    private var process: SpawnedProcess?
    private var continuation: CheckedContinuation<ClaudeTaskRunner.Result, Never>?
    private var resolved = false

    private var stdoutDone = false
    private var stderrDone = false
    private var exitCode: Int32?

    private var pendingLine = Data()
    private var stderrTail = Data()
    private var envelope: ClaudeTaskRunner.ResultEnvelope?

    private var logHandle: FileHandle?
    private var logBytes = 0
    private var logTruncated = false

    /// Set when we stop the process ourselves, so the exit that follows is
    /// reported as a timeout or a cancellation rather than a generic failure.
    private var stopReason: TaskRunStatus?

    init(logURL: URL, timeout: TimeInterval, onProgress: @escaping @Sendable (String) -> Void) {
        self.logURL = logURL
        self.timeout = timeout
        self.onProgress = onProgress

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
    }

    func attach(continuation: CheckedContinuation<ClaudeTaskRunner.Result, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    /// Attached after the spawn rather than with the continuation: a run that
    /// fails to start has a continuation to resolve but no process to stop.
    ///
    /// A cancellation that arrives in the window between the two is not lost —
    /// `stop` records its reason, and the timeout clock has not started yet.
    func attach(process: SpawnedProcess) {
        lock.lock()
        let alreadyStopping = stopReason
        self.process = process
        lock.unlock()

        // Cancelled between spawning and attaching: honour it now rather than
        // letting the process run on unsupervised.
        if let alreadyStopping { stop(as: alreadyStopping) }
    }

    // MARK: - Output

    func appendStdout(_ data: Data) {
        lock.lock()
        writeLog(data)
        pendingLine.append(data)

        var lines: [String] = []
        // 0x0A — split on newlines, keeping any partial trailing line for the
        // next chunk. A JSON object split across two reads is the normal case,
        // not an edge case.
        while let index = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine[pendingLine.startIndex ..< index]
            // Re-based rather than left as a slice: a `Data` slice keeps its
            // parent's indices, so repeated slicing here quietly makes
            // `startIndex` unequal to zero and every later assumption wrong.
            pendingLine = Data(pendingLine[pendingLine.index(after: index)...])
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        // Keep the buffer from growing without bound if the CLI emits an
        // enormous single line.
        if pendingLine.count > 1024 * 1024 { pendingLine.removeAll() }

        var progress: [String] = []
        for line in lines {
            if let found = ClaudeTaskRunner.resultEnvelope(fromJSONLine: line) { envelope = found }
            if let text = ClaudeTaskRunner.progressLine(fromJSONLine: line) { progress.append(text) }
        }
        lock.unlock()

        // Outside the lock: the callback hops to the main actor.
        if let last = progress.last { onProgress(last) }
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        writeLog(data)
        stderrTail.append(data)
        if stderrTail.count > ClaudeTaskRunner.maximumStderrBytes {
            stderrTail.removeFirst(stderrTail.count - ClaudeTaskRunner.maximumStderrBytes)
        }
    }

    /// Caller holds the lock.
    private func writeLog(_ data: Data) {
        guard let logHandle, !logTruncated else { return }
        if logBytes + data.count > ClaudeTaskRunner.maximumLogBytes {
            logTruncated = true
            try? logHandle.write(contentsOf: Data("\n--- output truncated ---\n".utf8))
            return
        }
        logBytes += data.count
        try? logHandle.write(contentsOf: data)
    }

    // MARK: - Lifecycle

    func streamFinished(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .stdout: stdoutDone = true
        case .stderr: stderrDone = true
        }
        lock.unlock()
        resolveIfReady()
    }

    func processExited(code: Int32) {
        lock.lock()
        exitCode = code
        lock.unlock()

        // A stream that never reaches EOF must not hang the queue forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + ClaudeTaskRunner.drainGrace) { [weak self] in
            self?.forceResolve()
        }
        resolveIfReady()
    }

    func startTimeoutClock() {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop(as: .timedOut)
        }
    }

    func failToStart(_ message: String) {
        resolve(
            ClaudeTaskRunner.Result(
                status: .failed, exitCode: nil, resultText: nil, sessionID: nil,
                costUSD: nil, errorMessage: message
            )
        )
    }

    /// Graceful first, forceful after a grace period.
    ///
    /// Signals the child's whole process group, not just the child. Claude Code
    /// runs its tools as child processes, and stopping only the CLI leaves those
    /// grandchildren running — invisible to the user and beyond the reach of
    /// anything in Tokenmax. `SpawnedProcess` puts the child in its own session
    /// precisely so the group can be signalled without touching Tokenmax; the
    /// guard that makes a negative pid safe lives in
    /// `SpawnedProcess.isSafeToSignalGroup`.
    func stop(as reason: TaskRunStatus) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        // Recorded even when there is no process yet, so a cancellation racing
        // the spawn is honoured once `attach(process:)` arrives.
        if stopReason == nil { stopReason = reason }
        guard let process, process.isRunning else { lock.unlock(); return }
        let bytesWritten = logBytes
        lock.unlock()

        // The byte count is the first thing worth knowing about a killed run:
        // zero means the CLI never produced anything, which is a different
        // problem from a task that was working and simply ran long.
        Log.shared.write(
            "autorun: stopping run (\(reason.rawValue)), pid \(process.pid), "
                + "\(bytesWritten) bytes of output so far"
        )
        process.terminateGroup()

        DispatchQueue.global().asyncAfter(deadline: .now() + ClaudeTaskRunner.terminationGrace) { [weak self] in
            guard let self else { return }
            lock.lock()
            let stillRunning = !resolved && (self.process?.isRunning ?? false)
            let target = self.process
            lock.unlock()
            if stillRunning {
                Log.shared.write("autorun: SIGKILL after \(Int(ClaudeTaskRunner.terminationGrace))s grace")
                target?.killGroup()
            }
        }
    }

    // MARK: - Resolution

    private func resolveIfReady() {
        lock.lock()
        let ready = exitCode != nil && stdoutDone && stderrDone && !resolved
        lock.unlock()
        guard ready else { return }
        resolve(buildResult())
    }

    private func forceResolve() {
        lock.lock()
        let pending = exitCode != nil && !resolved
        lock.unlock()
        guard pending else { return }
        resolve(buildResult())
    }

    private func buildResult() -> ClaudeTaskRunner.Result {
        lock.lock()
        let code = exitCode ?? -1
        let stderr = String(data: stderrTail, encoding: .utf8) ?? ""
        let envelope = self.envelope
        let stopReason = self.stopReason
        let bytesWritten = logBytes
        lock.unlock()

        // A run we stopped ourselves is reported as what we did to it, not as
        // whatever exit code the signal produced.
        if let stopReason {
            return ClaudeTaskRunner.Result(
                status: stopReason,
                exitCode: code,
                resultText: envelope?.result,
                sessionID: envelope?.sessionId,
                costUSD: envelope?.totalCostUsd,
                errorMessage: ClaudeTaskRunner.stoppedExplanation(
                    stopReason, stderr: stderr, bytesWritten: bytesWritten
                )
            )
        }

        return ClaudeTaskRunner.classify(exitCode: code, envelope: envelope, stderr: stderr)
    }

    private func resolve(_ result: ClaudeTaskRunner.Result) {
        lock.lock()
        guard !resolved, let continuation else { lock.unlock(); return }
        resolved = true
        self.continuation = nil
        try? logHandle?.close()
        logHandle = nil
        lock.unlock()

        continuation.resume(returning: result)
    }
}
