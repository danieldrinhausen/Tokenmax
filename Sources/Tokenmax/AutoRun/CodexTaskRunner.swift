import Foundation

/// Executes one queue task through the Codex App Server protocol.  Unlike a
/// bare `codex exec` invocation, this leaves Tokenmax with an opaque Codex
/// thread id that can be resumed by the same supported protocol later.
enum CodexTaskRunner {
    static let terminationGrace: TimeInterval = 10
    static let maximumLogBytes = ClaudeTaskRunner.maximumLogBytes
    static let maximumStderrBytes = ClaudeTaskRunner.maximumStderrBytes
    static let maximumResultCharacters = 256 * 1024

    static func run(
        task: TokenmaxTask,
        runID: UUID,
        prompt: String? = nil,
        resuming threadID: String? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async -> ClaudeTaskRunner.Result {
        let processBox = CodexProcessBox()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                runSynchronously(
                    task: task, runID: runID, prompt: prompt ?? task.prompt,
                    resuming: threadID, onProgress: onProgress, processBox: processBox
                )
            }.value
        } onCancel: {
            processBox.stop()
        }
    }

    private static func runSynchronously(
        task: TokenmaxTask,
        runID: UUID,
        prompt: String,
        resuming threadID: String?,
        onProgress: @escaping @Sendable (String) -> Void,
        processBox: CodexProcessBox
    ) -> ClaudeTaskRunner.Result {
        guard let executable = CodexCLIClient.locate() else {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "The codex CLI could not be found.")
        }
        guard task.expandedWorkingDirectory != nil, task.workingDirectoryExists else {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "Working directory not found.")
        }
        guard task.workingDirectoryReadable else {
            return .init(
                status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil,
                errorMessage: "macOS is blocking access to the working directory. Open the task and use Grant Access, or allow Tokenmax under System Settings → Privacy & Security → Files and Folders."
            )
        }

        var arguments: [String] = []
        // The same key Codex reads from ~/.codex/config.toml. Omitted when
        // unset so the user's own configured effort stands.
        if let effort = task.codex.reasoningEffort, !effort.isEmpty {
            arguments += ["-c", "model_reasoning_effort=\(effort)"]
        }
        arguments += ["-s", task.codex.sandbox.rawValue, "-a", "never", "app-server"]
        return executeAppServer(
            executable: executable,
            arguments: arguments,
            task: task,
            runID: runID,
            prompt: prompt,
            resuming: threadID,
            onProgress: onProgress,
            processBox: processBox
        )
    }

    /// Process and protocol plumbing split from CLI discovery so it can be
    /// exercised against a local fixture without starting a paid Codex turn.
    static func executeAppServer(
        executable: URL,
        arguments: [String],
        task: TokenmaxTask,
        runID: UUID,
        prompt: String,
        resuming threadID: String?,
        onProgress: @escaping @Sendable (String) -> Void,
        processBox: CodexProcessBox = CodexProcessBox(),
        timeout: TimeInterval? = nil
    ) -> ClaudeTaskRunner.Result {
        guard let directory = task.expandedWorkingDirectory else {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "Working directory not found.")
        }

        let input = Pipe(), output = Pipe(), errors = Pipe()

        let logURL = FileLocations.runLogFile(runID: runID)
        let observer = CodexRunObserver(logURL: logURL, onProgress: onProgress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { observer.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { observer.appendStderr(data) }
        }

        let process: SpawnedProcess
        do {
            process = try SpawnedProcess.spawn(
                executable: executable,
                arguments: arguments,
                directory: directory,
                environment: ProcessInfo.processInfo.environment,
                standardOutput: output.fileHandleForWriting,
                standardError: errors.fileHandleForWriting,
                standardInput: input.fileHandleForReading
            )
        }
        catch {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "Could not start Codex App Server: \(error.localizedDescription)")
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        processBox.attach(process, observer: observer)
        process.onExit { code in observer.processExited(code) }
        if processBox.isStopped {
            return .init(status: .cancelled, exitCode: nil, resultText: nil, sessionID: threadID, costUSD: nil, errorMessage: nil)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            processBox.terminate()
            try? input.fileHandleForWriting.close()
            processBox.clear()
        }

        func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            try send(["method": method, "id": id, "params": params])
            guard let response = observer.waitForResponse(id, timeout: 15) else {
                throw CodexAppServerClient.ClientError.timedOut(method)
            }
            if let error = response["error"] as? [String: Any] {
                throw CodexAppServerClient.ClientError.rpc(error["message"] as? String ?? "Codex rejected \(method).")
            }
            return (response["result"] as? [String: Any]) ?? [:]
        }

        do {
            _ = try request(1, "initialize", ["clientInfo": ["name": "tokenmax", "title": "Tokenmax", "version": "0.1"]])
            try send(["method": "initialized", "params": [:]])
            let thread: String
            if let threadID {
                let result = try request(2, "thread/resume", ["threadId": threadID])
                thread = ((result["thread"] as? [String: Any])?["id"] as? String) ?? threadID
            } else {
                var params: [String: Any] = ["cwd": directory.path]
                if let model = task.codex.model, !model.isEmpty { params["model"] = model }
                let result = try request(2, "thread/start", params)
                guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
                    throw CodexAppServerClient.ClientError.malformedResponse("Codex did not create a task thread.")
                }
                thread = id
            }
            _ = try request(3, "turn/start", [
                "threadId": thread,
                "input": [["type": "text", "text": prompt]],
                "cwd": directory.path,
                "sandboxPolicy": task.codex.sandbox.rawValue,
                "approvalPolicy": "never",
            ])
            let runtimeLimit = timeout ?? Double(task.codex.maximumRuntimeMinutes) * 60
            guard let completion = observer.waitForCompletion(timeout: runtimeLimit) else {
                if processBox.isStopped {
                    return .init(status: .cancelled, exitCode: observer.exitCode, resultText: observer.finalText, sessionID: thread, costUSD: nil, errorMessage: nil)
                }
                processBox.stop()
                return .init(status: .timedOut, exitCode: observer.exitCode, resultText: observer.finalText, sessionID: thread, costUSD: nil, errorMessage: "Codex did not finish within the task runtime limit.")
            }
            let succeeded = completion == "completed"
            return .init(
                status: succeeded ? .completed : .failed, exitCode: succeeded ? 0 : 1,
                resultText: observer.finalText, sessionID: thread, costUSD: nil,
                errorMessage: succeeded ? nil : (observer.errorText ?? "Codex ended with \(completion).")
            )
        } catch {
            if processBox.isStopped {
                return .init(status: .cancelled, exitCode: nil, resultText: observer.finalText, sessionID: threadID, costUSD: nil, errorMessage: nil)
            }
            return .init(status: .failed, exitCode: nil, resultText: observer.finalText, sessionID: threadID, costUSD: nil, errorMessage: error.localizedDescription)
        }
    }
}

/// Connects structured-concurrency cancellation to the App Server process.
/// `Task.cancel()` alone does not terminate a child `Process`, which would let
/// a stopped queue task continue changing files in the background.
final class CodexProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: SpawnedProcess?
    private var observer: CodexRunObserver?
    private var wasStopped = false

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return wasStopped
    }

    fileprivate func attach(_ process: SpawnedProcess, observer: CodexRunObserver) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        self.observer = observer
        if wasStopped {
            observer.cancel()
            stop(process)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        process = nil
        observer = nil
    }

    func stop() {
        lock.lock()
        wasStopped = true
        let process = process
        let observer = observer
        lock.unlock()
        observer?.cancel()
        if let process { stop(process) }
    }

    /// Normal protocol completion still leaves the App Server waiting on stdin.
    /// Closing it is lifecycle cleanup, not a user cancellation.
    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        if let process { stop(process) }
    }

    private func stop(_ process: SpawnedProcess) {
        guard process.isRunning else { return }
        process.terminateGroup()
        DispatchQueue.global().asyncAfter(deadline: .now() + CodexTaskRunner.terminationGrace) {
            if process.isRunning { process.killGroup() }
        }
    }
}

private final class CodexRunObserver: @unchecked Sendable {
    private let lock = NSCondition()
    private var pending = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var completion: String?
    private var cancelled = false
    private var serverExitCode: Int32?
    private var storedFinalText = ""
    private var storedErrorText: String?
    private var stderrTail = Data()
    private var resultTruncated = false
    private let logHandle: FileHandle?
    private var logBytes = 0
    private var logTruncated = false
    private let onProgress: @Sendable (String) -> Void

    init(logURL: URL, onProgress: @escaping @Sendable (String) -> Void) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        self.onProgress = onProgress
    }

    deinit { try? logHandle?.close() }

    func append(_ data: Data) {
        lock.lock()
        writeLog(data)
        pending.append(data)
        var progress: String?
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            progress = handle(line) ?? progress
        }
        if pending.count > 1024 * 1024 { pending.removeAll() }
        lock.unlock()
        if let progress { onProgress(progress) }
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        writeLog(data)
        stderrTail.append(data)
        if stderrTail.count > CodexTaskRunner.maximumStderrBytes {
            stderrTail.removeFirst(stderrTail.count - CodexTaskRunner.maximumStderrBytes)
        }
        lock.unlock()
    }

    /// Caller holds `lock`; returns the newest progress text for delivery after
    /// unlocking so a UI callback can never block the protocol reader.
    private func handle(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = (root["id"] as? NSNumber)?.intValue {
            responses[id] = root
            lock.broadcast()
            return nil
        }
        guard let method = root["method"] as? String, let params = root["params"] as? [String: Any] else { return nil }
        if method == "turn/completed" {
            completion = (params["turn"] as? [String: Any])?["status"] as? String ?? "failed"
            lock.broadcast()
        }
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
            let room = max(0, CodexTaskRunner.maximumResultCharacters - storedFinalText.count)
            if room > 0 { storedFinalText += String(delta.prefix(room)) }
            if delta.count > room { resultTruncated = true }
            return String(delta.prefix(90))
        }
        if method == "turn/failed" { storedErrorText = params["error"] as? String }
        return nil
    }

    private func writeLog(_ data: Data) {
        guard let logHandle, !logTruncated else { return }
        if logBytes + data.count > CodexTaskRunner.maximumLogBytes {
            logTruncated = true
            try? logHandle.write(contentsOf: Data("\n--- output truncated ---\n".utf8))
            return
        }
        logBytes += data.count
        try? logHandle.write(contentsOf: data)
    }

    func waitForResponse(_ id: Int, timeout: TimeInterval) -> [String: Any]? {
        wait(timeout: timeout) { responses[id] != nil }.flatMap { _ in responses.removeValue(forKey: id) }
    }
    func waitForCompletion(timeout: TimeInterval) -> String? {
        wait(timeout: timeout) { completion != nil || serverExitCode != nil }.flatMap { _ in completion }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }
    func processExited(_ code: Int32) {
        lock.lock()
        serverExitCode = code
        lock.broadcast()
        lock.unlock()
    }
    var finalText: String? {
        lock.lock(); defer { lock.unlock() }
        guard !storedFinalText.isEmpty else { return nil }
        return storedFinalText + (resultTruncated ? "\n\n[Output truncated by Tokenmax.]" : "")
    }
    var errorText: String? {
        lock.lock(); defer { lock.unlock() }
        if let storedErrorText { return storedErrorText }
        let stderr = String(data: stderrTail, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr?.isEmpty == false ? stderr : nil
    }
    var exitCode: Int32? {
        lock.lock(); defer { lock.unlock() }
        return serverExitCode
    }
    private func wait(timeout: TimeInterval, until predicate: () -> Bool) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while !predicate() && !cancelled && Date() < deadline { lock.wait(until: deadline) }
        return predicate()
    }
}
