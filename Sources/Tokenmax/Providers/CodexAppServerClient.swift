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

    static let timeout: TimeInterval = 12

    func readAccountAndLimits() async throws -> (Account, RateLimits) {
        try await Task.detached(priority: .utility) {
            try self.withSession { request in
                let accountResult = try request(2, "account/read", ["refreshToken": false])
                let limitsResult = try request(3, "account/rateLimits/read", [:])
                return (Self.decodeAccount(accountResult), try Self.decodeLimits(limitsResult))
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
        guard let executable = CodexCLIClient.locate() else { throw ClientError.notInstalled }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = ProcessInfo.processInfo.environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let reader = RPCReader()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { reader.append(data) }
        }

        do { try process.run() }
        catch { throw ClientError.rpc("Could not start Codex App Server: \(error.localizedDescription)") }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
        }

        func send(_ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["method": method, "id": id, "params": params])
            guard let response = reader.wait(for: id, timeout: Self.timeout) else {
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

private final class RPCReader: @unchecked Sendable {
    private let lock = NSCondition()
    private var pending = Data()
    private var responses: [Int: [String: Any]] = [:]

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue
            else { continue }
            responses[id] = object
            lock.broadcast()
        }
        lock.unlock()
    }

    func wait(for id: Int, timeout: TimeInterval) -> [String: Any]? {
        let limit = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while responses[id] == nil && Date() < limit {
            lock.wait(until: limit)
        }
        return responses.removeValue(forKey: id)
    }
}
