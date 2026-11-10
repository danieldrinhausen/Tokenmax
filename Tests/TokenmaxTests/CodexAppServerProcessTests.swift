import Foundation
import Testing

@testable import Tokenmax

/// The App Server client against stand-in children: one that dies at once, one
/// that floods stderr, one that ignores SIGTERM. The real `codex` is never run.
@Suite("Codex App Server client process handling")
struct CodexAppServerProcessTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-codex-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Answers the handshake and the two reads the refresh makes.
    private static let handshake = """
    read l; echo '{"id":1,"result":{}}'
    read l
    read l; echo '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}'
    read l; echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300}}}}'
    """

    @Test("A child that exits at once fails the read promptly, naming what it said, not after the timeout")
    func earlyExitFailsFast() async throws {
        let url = try script("echo 'unknown flag --frob' >&2\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CodexAppServerClient(executable: url, arguments: [])

        let started = Date()
        do {
            _ = try await client.readAccountAndLimits()
            Issue.record("expected a failure")
        } catch let error as CodexAppServerClient.ClientError {
            guard case let .rpc(message) = error else { Issue.record("got \(error)"); return }
            #expect(message.contains("exited"))
            #expect(message.contains("unknown flag"))
        }
        #expect(Date().timeIntervalSince(started) < CodexAppServerClient.timeout / 2)
    }

    @Test("A child that writes megabytes to stderr cannot block the read")
    func stderrIsDrained() async throws {
        let url = try script("""
        head -c 3000000 /dev/zero | tr '\\000' x >&2
        \(Self.handshake)
        read l
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = CodexAppServerClient(executable: url, arguments: [])

        let (account, limits, _) = try await client.readAccountAndLimits()
        #expect(account.isChatGPTManaged)
        #expect(limits.primary?.durationMinutes == 300)
    }

    @Test("A child that ignores SIGTERM is killed once the read is done")
    func stubbornChildIsKilled() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
        let url = try script("""
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        \(Self.handshake)
        while :; do sleep 1; done
        """)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let client = CodexAppServerClient(executable: url, arguments: [])

        _ = try await client.readAccountAndLimits()

        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { gone = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone)
    }

    // MARK: - The reader

    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func add(_ line: Data) { lock.withLock { lines.append(line) } }
        var all: [Data] { lock.withLock { lines } }
    }

    @Test("A server request is refused and never taken for a reply with the same id")
    func serverRequestIsNotAResponse() throws {
        let replies = Replies()
        let reader = CodexRPCReader { replies.add($0) }

        reader.append(Data(#"{"id":2,"method":"item/approval/request","params":{}}"#.utf8 + [0x0A]))
        #expect(reader.wait(for: 2, timeout: 0.05) == nil)

        let refusal = try #require(replies.all.first)
        let object = try #require(JSONSerialization.jsonObject(with: refusal) as? [String: Any])
        #expect((object["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(object["id"] as? Int == 2)

        // The real reply still lands, afterwards.
        reader.append(Data(#"{"id":2,"result":{"ok":true}}"#.utf8 + [0x0A]))
        #expect(reader.wait(for: 2, timeout: 0.5)?["result"] != nil)
    }

    @Test("Notifications and unrelated lines are ignored and need no reply")
    func notificationsAreQuiet() {
        let replies = Replies()
        let reader = CodexRPCReader { replies.add($0) }
        reader.append(Data(#"{"method":"thread/started","params":{}}"#.utf8 + [0x0A]))
        reader.append(Data("not json\n".utf8))
        #expect(replies.all.isEmpty)
        #expect(reader.wait(for: 1, timeout: 0.05) == nil)
    }

    @Test("Closing wakes a waiter at once, and a reply that arrived before the close is still delivered")
    func closeWakesWaiters() async {
        let reader = CodexRPCReader { _ in }
        reader.append(Data(#"{"id":7,"result":{}}"#.utf8 + [0x0A]))
        reader.close()
        #expect(reader.wait(for: 7, timeout: 5) != nil)

        let started = Date()
        #expect(reader.wait(for: 8, timeout: 5) == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(reader.isClosed)
    }
}
