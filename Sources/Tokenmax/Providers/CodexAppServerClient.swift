import Foundation

/// Minimal, bounded JSON-RPC client for Codex App Server.
///
/// Tokenmax deliberately starts a fresh read-only server for a refresh. This
/// avoids retaining an agent process in the background and leaves Codex fully
/// responsible for its stored CLI credentials and token refreshes.
final class CodexAppServerClient: @unchecked Sendable {
    enum ClientError: Error, LocalizedError {
        case notInstalled
        case timedOut(String)
        case rpc(String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "The codex CLI could not be found."
            case let .timedOut(method): "Codex did not answer \(method) in time."
            case let .rpc(message), let .malformedResponse(message): message
            }
        }
    }

    struct Account: Sendable, Equatable {
        var authMode: String?
        var planName: String?
        var email: String?

        var isChatGPTManaged: Bool { authMode == "chatgpt" || authMode == "chatgptAuthTokens" }
    }

    struct RateLimits: Sendable {
        struct Window: Sendable, Equatable {
            var usedPercent: Double?
            var durationMinutes: Int?
            var resetsAt: Date?
        }

        var primary: Window?
        var secondary: Window?
        var additional: [(id: String, name: String?, primary: Window?, secondary: Window?)]
    }

    /// A promotional reset is separate from purchased credits and rate-limit
    /// windows. Tokenmax only reports it: redeeming one changes the account and
    /// belongs in Codex, where the user can review the offer before spending it.
    struct RateLimitResetCredits: Sendable, Equatable {
        var availableCount: Int
        var nearestExpiry: Date?
        /// The available credits one by one, soonest expiry first.
        var credits: [BankedReset] = []
    }

    static let timeout: TimeInterval = 12

    /// Seconds a child gets to exit after SIGTERM before it is killed.
    static let terminationGrace: TimeInterval = 2

    private let executableOverride: URL?
    private let arguments: [String]

    /// The overrides exist so tests can stand a script in for `codex`; the app
    /// uses the defaults.
    init(
        executable: URL? = nil,
        arguments: [String] = ["-s", "read-only", "-a", "never", "app-server"]
    ) {
        executableOverride = executable
        self.arguments = arguments
    }

    func readAccountAndLimits() async throws -> (Account, RateLimits, RateLimitResetCredits?) {
        try await Task.detached(priority: .utility) {
            try self.withSession { request in
                let accountResult = try request(2, "account/read", ["refreshToken": false])
                let limitsResult = try request(3, "account/rateLimits/read", [:])
                return (
                    Self.decodeAccount(accountResult),
                    try Self.decodeLimits(limitsResult),
                    Self.decodeResetCredits(limitsResult)
                )
            }
        }.value
    }

    /// The models this account may choose between, as Codex itself reports them.
    ///
    /// Fetched rather than hardcoded for the same reason the Claude catalog is:
    /// a model released next month has to appear without a Tokenmax release, and
    /// the reasoning levels differ per model in a way no static list can track.
    func readModels() async throws -> [CodexCatalogModel] {
        try await Task.detached(priority: .utility) {
            try self.withSession { request in
                Self.decodeModels(try request(2, "model/list", [:]))
            }
        }.value
    }

    /// One short-lived read-only App Server, and the JSON-RPC handshake every
    /// read needs before it can ask anything.
    ///
    /// Tokenmax deliberately starts a fresh server per read rather than keeping
    /// one alive: no agent process lingers in the background, and Codex stays
    /// fully responsible for its stored credentials and token refreshes.
    private func withSession<T>(
        _ body: (_ request: (Int, String, [String: Any]) throws -> [String: Any]) throws -> T
    ) throws -> T {
        guard let executable = executableOverride ?? CodexCLIClient.locate() else { throw ClientError.notInstalled }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let stdin = input.fileHandleForWriting
        let reader = CodexRPCReader { line in try? stdin.write(contentsOf: line) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                // EOF is the child going away, whatever its exit status says
                // or whenever it says it: nothing more will ever be answered.
                reader.close()
            } else {
                reader.append(data)
            }
        }
        // Drained and kept only as a short tail. Nothing reads stderr otherwise,
        // and a chatty child fills the pipe's buffer and blocks on its next
        // write — the read then "times out" on a process that is merely stuck.
        let stderrTail = BoundedTail(limit: 2048)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(data) }
        }
        // A beat of grace: the exit can be reported before the readability
        // handler has delivered the child's last bytes, and closing at once would
        // turn a reply that did arrive into "exited before answering".
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { reader.close() }
        }

        do { try process.run() }
        catch { throw ClientError.rpc("Could not start Codex App Server: \(error.localizedDescription)") }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            Self.stop(process)
            try? input.fileHandleForWriting.close()
        }

        func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["method": method, "id": id, "params": params])
            guard let response = reader.wait(for: id, timeout: Self.timeout) else {
                // A child that has already gone is not "slow": say so at once
                // instead of after the full timeout, with whatever it printed.
                if reader.isClosed {
                    let detail = stderrTail.lastLine.map { " It said: \($0)" } ?? ""
                    throw ClientError.rpc("Codex App Server exited before answering \(method).\(detail)")
                }
                throw ClientError.timedOut(method)
            }
            if let error = response["error"] as? [String: Any] {
                throw ClientError.rpc(error["message"] as? String ?? "Codex App Server rejected \(method).")
            }
            guard let result = response["result"] as? [String: Any] else {
                throw ClientError.malformedResponse("Codex App Server returned no result for \(method).")
            }
            return result
        }

        _ = try request(1, "initialize", [
            "clientInfo": ["name": "tokenmax", "title": "Tokenmax", "version": "0.1"]
        ])
        try send(["method": "initialized", "params": [:]])
        return try body(request)
    }

    /// SIGTERM, then SIGKILL if the child is still there after the grace period.
    /// `terminate()` alone is a request: a child that ignores or is stuck in it
    /// would outlive the refresh, and every refresh would leave another.
    static func stop(_ process: Process, grace: TimeInterval = terminationGrace) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// `model/list` returns `{data: [Model]}`. Only the fields the editor needs
    /// are read; everything else is ignored rather than modelled, so a field
    /// Codex adds cannot break the decode.
    ///
    /// Hidden models are dropped: Codex marks them as kept out of its own
    /// picker, and Tokenmax has no better claim to show them.
    static func decodeModels(_ result: [String: Any]) -> [CodexCatalogModel] {
        let data = result["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            if entry["hidden"] as? Bool == true { return nil }
            return CodexCatalogModel(
                id: id,
                displayName: (entry["displayName"] as? String) ?? id,
                summary: entry["description"] as? String,
                isDefault: (entry["isDefault"] as? Bool) ?? false,
                reasoningEfforts: reasoningEfforts(entry["supportedReasoningEfforts"])
            )
        }
    }

    /// Codex 0.146 reports each level as `{reasoningEffort, description}`;
    /// earlier App Server versions sent bare strings. Accept both, so an
    /// upgrade in either direction does not empty the picker.
    private static func reasoningEfforts(_ value: Any?) -> [String] {
        guard let levels = value as? [Any] else { return [] }
        return levels.compactMap { level in
            if let name = level as? String { return name }
            return (level as? [String: Any])?["reasoningEffort"] as? String
        }
    }

    static func decodeAccount(_ result: [String: Any]) -> Account {
        let account = (result["account"] as? [String: Any]) ?? result
        return Account(
            // Codex 0.146 reports `type: "chatgpt"`; older App Server
            // versions used `authMode`. Accept both shapes during upgrades.
            authMode: (account["authMode"] as? String)
                ?? (account["type"] as? String)
                ?? (result["authMode"] as? String)
                ?? (result["type"] as? String),
            planName: (account["planType"] as? String) ?? (result["planType"] as? String),
            email: (account["email"] as? String) ?? (result["email"] as? String)
        )
    }

    static func decodeLimits(_ result: [String: Any]) throws -> RateLimits {
        guard let root = result["rateLimits"] as? [String: Any] else {
            throw ClientError.malformedResponse("Codex did not report ChatGPT rate limits for this account.")
        }
        let byID = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        let additional = byID.compactMap { key, value -> (String, String?, RateLimits.Window?, RateLimits.Window?)? in
            guard let bucket = value as? [String: Any] else { return nil }
            return (key, bucket["limitName"] as? String, window(bucket["primary"]), window(bucket["secondary"]))
        }
        return RateLimits(primary: window(root["primary"]), secondary: window(root["secondary"]), additional: additional)
    }

    /// `rateLimitResetCredits` arrived after the original window response. Its
    /// absence means an older CLI did not report the feature, not that an
    /// account has no resets, so it remains optional all the way to the UI.
    static func decodeResetCredits(_ result: [String: Any]) -> RateLimitResetCredits? {
        guard let value = result["rateLimitResetCredits"] as? [String: Any],
              let availableCount = (value["availableCount"] as? NSNumber)?.intValue
        else { return nil }

        let available = (value["credits"] as? [[String: Any]] ?? []).compactMap { credit -> BankedReset? in
            guard credit["status"] as? String == "available" else { return nil }
            let expiry = (credit["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return BankedReset(title: credit["title"] as? String, expiresAt: expiry)
        }
        .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return RateLimitResetCredits(
            availableCount: availableCount,
            nearestExpiry: available.compactMap(\.expiresAt).min(),
            credits: available
        )
    }

    private static func window(_ value: Any?) -> RateLimits.Window? {
        guard let value = value as? [String: Any] else { return nil }
        let timestamp = (value["resetsAt"] as? Double) ?? (value["resetsAt"] as? NSNumber)?.doubleValue
        return RateLimits.Window(
            usedPercent: (value["usedPercent"] as? Double) ?? (value["usedPercent"] as? NSNumber)?.doubleValue,
            durationMinutes: (value["windowDurationMins"] as? Int) ?? (value["windowDurationMins"] as? NSNumber)?.intValue,
            resetsAt: timestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// The last few kilobytes of a child's stderr, for an error message.
private final class BoundedTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    /// The last non-empty line, shortened — enough to name the failure, not
    /// enough to put a log in the UI.
    var lastLine: String? {
        let text = lock.withLock { String(decoding: data, as: UTF8.self) }
        guard let line = text.split(whereSeparator: \.isNewline).last else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }
}

/// Reads JSON-RPC lines from the App Server's stdout.
///
/// A line with an `id` is only a reply to one of ours when it has no `method`:
/// the server also sends *requests* with ids of its own (an approval, an
/// elicitation), and filing those as responses let one overwrite a real reply
/// with the same id. They are refused instead, as `CodexTaskRunner` does —
/// nobody is there to answer — and never enter the response map.
final class CodexRPCReader: @unchecked Sendable {
    private let lock = NSCondition()
    private var pending = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false
    private let reply: @Sendable (Data) -> Void

    init(reply: @escaping @Sendable (Data) -> Void) { self.reply = reply }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// The stream ended. Wakes anyone waiting so they fail now, not at the timeout.
    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }

    func append(_ data: Data) {
        var replies: [Data] = []
        lock.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch CodexMessage.classify(object) {
            case let .response(id):
                responses[id] = object
                lock.broadcast()
            case let .serverRequest(id, method):
                Log.shared.write("codex: app-server asked \(method); refused, unattended")
                replies.append(CodexMessage.refusal(id: id, method: method))
            case .notification, .other:
                break
            }
        }
        // A runaway line with no newline must not grow without bound.
        if pending.count > 1024 * 1024 { pending.removeAll() }
        lock.unlock()
        // Outside the lock: a full stdin pipe must not stall the reader.
        for line in replies { reply(line) }
    }

    func wait(for id: Int, timeout: TimeInterval) -> [String: Any]? {
        let limit = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while responses[id] == nil, !closed, Date() < limit {
            lock.wait(until: limit)
        }
        return responses.removeValue(forKey: id)
    }
}
