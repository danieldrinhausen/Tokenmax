import Foundation

/// Executes one queue task through the Codex App Server protocol.  Unlike a
/// bare `codex exec` invocation, this leaves Tokenmax with an opaque Codex
/// thread id that can be resumed by the same supported protocol later.
enum CodexTaskRunner {
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
        guard let directory = task.expandedWorkingDirectory, task.workingDirectoryExists else {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "Working directory not found.")
        }

        let process = Process()
        process.executableURL = executable
        var arguments: [String] = []
        // The same key Codex reads from ~/.codex/config.toml. Omitted when
        // unset so the user's own configured effort stands.
        if let effort = task.codex.reasoningEffort, !effort.isEmpty {
            arguments += ["-c", "model_reasoning_effort=\(effort)"]
        }
        arguments += ["-s", task.codex.sandbox.rawValue, "-a", "never", "app-server"]
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors

        let logURL = FileLocations.runLogFile(runID: runID)
        let observer = CodexRunObserver(logURL: logURL, onProgress: onProgress)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { observer.append(data) }
        }

        do { try process.run() }
        catch {
            return .init(status: .failed, exitCode: nil, resultText: nil, sessionID: nil, costUSD: nil, errorMessage: "Could not start Codex App Server: \(error.localizedDescription)")
        }
        processBox.attach(process, observer: observer)
        if processBox.isStopped {
            return .init(status: .cancelled, exitCode: nil, resultText: nil, sessionID: threadID, costUSD: nil, errorMessage: nil)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
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
            guard let completion = observer.waitForCompletion(timeout: Double(task.codex.maximumRuntimeMinutes) * 60) else {
                if processBox.isStopped {
                    return .init(status: .cancelled, exitCode: nil, resultText: observer.finalText, sessionID: thread, costUSD: nil, errorMessage: nil)
                }
                return .init(status: .timedOut, exitCode: nil, resultText: observer.finalText, sessionID: thread, costUSD: nil, errorMessage: "Codex did not finish within the task runtime limit.")
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
private final class CodexProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var observer: CodexRunObserver?
    private var wasStopped = false

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return wasStopped
    }

    func attach(_ process: Process, observer: CodexRunObserver) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        self.observer = observer
        if wasStopped {
            observer.cancel()
            if process.isRunning { process.terminate() }
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
        if process?.isRunning == true { process?.terminate() }
    }
}

private final class CodexRunObserver: @unchecked Sendable {
    private let lock = NSCondition()
    private var pending = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var completion: String?
    private var cancelled = false
    private(set) var finalText: String?
    private(set) var errorText: String?
    private let logHandle: FileHandle?
    private let onProgress: @Sendable (String) -> Void

    init(logURL: URL, onProgress: @escaping @Sendable (String) -> Void) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        self.onProgress = onProgress
    }

    deinit { try? logHandle?.close() }

    func append(_ data: Data) {
        lock.lock()
        try? logHandle?.write(contentsOf: data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            handle(line)
        }
        lock.unlock()
    }

    private func handle(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = (root["id"] as? NSNumber)?.intValue { responses[id] = root; lock.broadcast(); return }
        guard let method = root["method"] as? String, let params = root["params"] as? [String: Any] else { return }
        if method == "turn/completed" {
            completion = (params["turn"] as? [String: Any])?["status"] as? String ?? "failed"
            lock.broadcast()
        }
        if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
            finalText = (finalText ?? "") + delta
            onProgress(String(delta.prefix(90)))
        }
        if method == "turn/failed" { errorText = params["error"] as? String }
    }

    func waitForResponse(_ id: Int, timeout: TimeInterval) -> [String: Any]? {
        wait(timeout: timeout) { responses[id] != nil }.flatMap { _ in responses.removeValue(forKey: id) }
    }
    func waitForCompletion(timeout: TimeInterval) -> String? {
        wait(timeout: timeout) { completion != nil }.flatMap { _ in completion }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }
    private func wait(timeout: TimeInterval, until predicate: () -> Bool) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while !predicate() && !cancelled && Date() < deadline { lock.wait(until: deadline) }
        return predicate()
    }
}
