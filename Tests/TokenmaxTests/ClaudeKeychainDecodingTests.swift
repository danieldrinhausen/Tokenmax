import Foundation
import Testing

@testable import Tokenmax

@Suite("Claude keychain decoding")
struct ClaudeKeychainDecodingTests {
    /// The login item: the shape Claude Code writes once you are authenticated.
    private let loginBlob = Data("""
    {
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat-example",
        "refreshToken": "sk-ant-ort-example",
        "expiresAt": 1785500000000,
        "refreshTokenExpiresAt": 1788000000000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "rateLimitTier": "default"
      }
    }
    """.utf8)

    /// The sibling item that shares the service name and holds MCP server
    /// tokens only. Reading this one instead of the login is what produced
    /// "The Claude Code credentials could not be read." on a working machine.
    private let mcpOnlyBlob = Data("""
    {
      "mcpOAuth": {
        "posthog|b66af36bf9e35c01": {
          "serverName": "posthog",
          "accessToken": "phx-example",
          "clientId": "client-example"
        }
      }
    }
    """.utf8)

    @Test("Decodes a login blob, converting epoch milliseconds")
    func decodesLogin() throws {
        let credentials = try #require(ClaudeKeychain.decode(loginBlob))

        #expect(credentials.accessToken == "sk-ant-oat-example")
        #expect(credentials.refreshToken == "sk-ant-ort-example")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_785_500_000))
    }

    @Test("Rejects the MCP-only sibling rather than mistaking it for a login")
    func rejectsMCPOnlyItem() {
        #expect(ClaudeKeychain.decode(mcpOnlyBlob) == nil)
    }

    @Test("Rejects malformed JSON")
    func rejectsGarbage() {
        #expect(ClaudeKeychain.decode(Data("not json".utf8)) == nil)
        #expect(ClaudeKeychain.decode(Data("{}".utf8)) == nil)
    }

    @Test("Picks the login out of a multi-item service, whatever the order")
    func selectsLoginFromSeveralItems() throws {
        for blobs in [[mcpOnlyBlob, loginBlob], [loginBlob, mcpOnlyBlob]] {
            let picked = try #require(blobs.lazy.compactMap(ClaudeKeychain.decode).first)
            #expect(picked.accessToken == "sk-ant-oat-example")
        }
    }

    /// Ordering only decides how many consent dialogs the user sees — one per
    /// item opened — so the login wants to be first.
    @Suite("Candidate ordering")
    struct OrderingTests {
        private func items(_ accounts: [String?]) -> [ClaudeKeychain.Item] {
            accounts.map { ClaudeKeychain.Item(account: $0, ref: NSString(string: $0 ?? "nil")) }
        }

        private func accounts(_ items: [ClaudeKeychain.Item]) -> [String?] {
            items.map(\.account)
        }

        @Test("Puts the item named for the current user first")
        func prefersCurrentUser() {
            let ordered = ClaudeKeychain.ordered(items(["unknown", "victor"]), user: "victor")
            #expect(accounts(ordered) == ["victor", "unknown"])
        }

        @Test("Leaves an already-first login where it is")
        func alreadyFirst() {
            let ordered = ClaudeKeychain.ordered(items(["victor", "unknown"]), user: "victor")
            #expect(accounts(ordered) == ["victor", "unknown"])
        }

        @Test("Keeps keychain order when no account matches the user")
        func stableWithoutMatch() {
            let ordered = ClaudeKeychain.ordered(items(["unknown", "other", nil]), user: "victor")
            #expect(accounts(ordered) == ["unknown", "other", nil])
        }

        @Test("Handles an empty list")
        func empty() {
            #expect(ClaudeKeychain.ordered([], user: "victor").isEmpty)
        }
    }

    @Test("Treats a login with no expiry as unexpired")
    func missingExpiryIsNotExpired() throws {
        let blob = Data("""
        { "claudeAiOauth": { "accessToken": "a", "subscriptionType": "pro" } }
        """.utf8)
        let credentials = try #require(ClaudeKeychain.decode(blob))

        #expect(credentials.expiresAt == nil)
        #expect(credentials.isExpired == false)
    }
}
