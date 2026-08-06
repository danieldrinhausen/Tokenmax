import Foundation
import os
import Security

/// Reads the OAuth credentials Claude Code stores in the login keychain.
///
/// The item is owned by the `claude` binary, so the first read from Tokenmax
/// triggers a macOS consent prompt. That grant is bound to our code signature —
/// with ad-hoc signing the signature changes on every rebuild, so the prompt
/// reappears after each `make install` during development. It is genuinely
/// one-time for a stable installed build.
///
/// Consent is per *item*, and several items share this service name — so
/// reading one we do not need costs the user a dialog for nothing. Hence
/// `rememberedAccount` and the ordering in `ordered(_:user:)`: both exist only
/// to keep the number of prompts at one.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    /// The account whose item last yielded a login, so later reads go straight
    /// there instead of walking the siblings again. Process-lifetime only;
    /// a wrong guess costs one failed read and falls back to the full walk.
    private static let rememberedAccount = OSAllocatedUnfairLock<String?>(initialState: nil)

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let subscriptionType: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    enum KeychainError: Error, LocalizedError {
        case notFound
        case accessDenied
        case malformed
        case unexpected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound: "Claude Code is installed but not authenticated."
            case .accessDenied: "Tokenmax was denied access to the Claude Code keychain item."
            case .malformed: "The Claude Code credentials could not be read."
            case let .unexpected(status): "Keychain error \(status)."
            }
        }
    }

    private struct Payload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            /// Epoch **milliseconds**.
            let expiresAt: Double?
            let subscriptionType: String?
        }

        /// Absent in the sibling item that holds only `mcpOAuth`, hence optional.
        let claudeAiOauth: OAuth?
    }

    static func readCredentials() throws -> Credentials {
        // Claude Code keeps more than one item under this service name: the
        // login sits under an account named for the macOS user, while MCP
        // server tokens land in a sibling under "unknown" that carries no
        // `claudeAiOauth` at all. `kSecMatchLimitOne` returned whichever the
        // keychain listed first, so a machine with MCP servers configured
        // failed with .malformed while perfectly logged in.
        //
        // Which item is the login is settled by content, never by account
        // name — that name is Claude Code's business and has already changed
        // once. The account is used only to *order* the candidates, because
        // every item we open costs the user a separate consent dialog.
        if let account = rememberedAccount.withLock({ $0 }),
           case let .data(data) = copyData(account: account),
           let credentials = decode(data)
        {
            return credentials
        }

        let items = try copyItems()

        var denied = false
        for item in ordered(items, user: NSUserName()) {
            switch copyData(for: item.ref) {
            case let .data(data):
                if let credentials = decode(data) {
                    rememberedAccount.withLock { $0 = item.account }
                    return credentials
                }
            case let .failure(code) where isDenial(code):
                denied = true
            case .failure:
                continue
            }
        }

        rememberedAccount.withLock { $0 = nil }

        // A denial we could not see past is worth reporting as one: "grant
        // access" is actionable, "could not be read" is not.
        throw denied ? KeychainError.accessDenied : KeychainError.malformed
    }

    /// One candidate item: its account name, and a handle to open it with.
    struct Item {
        let account: String?
        let ref: AnyObject
    }

    /// Candidates likeliest to be the login first.
    ///
    /// Pure, and separated out so the rule is testable without a keychain.
    /// Only an optimisation — a wrong guess costs one extra prompt, never a
    /// wrong answer, because `decode` still has the final say.
    static func ordered(_ items: [Item], user: String) -> [Item] {
        items.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.account == user
                let right = rhs.element.account == user
                // Stable: equal-priority items keep their keychain order.
                return left == right ? lhs.offset < rhs.offset : left
            }
            .map(\.element)
    }

    /// Every item under the service, with the account names needed to order
    /// them.
    ///
    /// Deliberately *not* `kSecReturnData` — the legacy generic-password store
    /// rejects `kSecMatchLimitAll` combined with returning data, failing the
    /// whole query with `errSecParam` (-50) rather than returning what it can.
    /// Enumerating costs no prompt; opening an item does.
    private static func copyItems() throws -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.notFound
        case let code where isDenial(code):
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unexpected(status)
        }

        // `kSecMatchLimitAll` yields an array, but a lone match can still come
        // back bare.
        let dictionaries: [[String: Any]]
        if let many = result as? [[String: Any]] {
            dictionaries = many
        } else if let one = result as? [String: Any] {
            dictionaries = [one]
        } else {
            throw KeychainError.notFound
        }

        let items = dictionaries.compactMap { attributes -> Item? in
            guard let ref = attributes[kSecValueRef as String] else { return nil }
            return Item(
                account: attributes[kSecAttrAccount as String] as? String,
                ref: ref as AnyObject
            )
        }

        guard !items.isEmpty else { throw KeychainError.notFound }
        return items
    }

    private enum ItemData {
        case data(Data)
        case failure(OSStatus)
    }

    /// Opens one item by account name — the fast path, so a second read in the
    /// same session does not re-prompt for siblings it already rejected.
    private static func copyData(account: String) -> ItemData {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return copyData(matching: query)
    }

    /// The consent prompt, if there is one, happens here rather than in the
    /// enumeration above.
    private static func copyData(for item: AnyObject) -> ItemData {
        copyData(matching: [
            kSecValueRef as String: item,
            kSecReturnData as String: true,
        ])
    }

    private static func copyData(matching query: [String: Any]) -> ItemData {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data else { return .failure(errSecDecode) }
        return .data(data)
    }

    private static func isDenial(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
    }

    /// The pure half of `readCredentials`, so the item-selection rule is
    /// testable without a keychain. Returns nil for anything that is not a
    /// login blob — malformed JSON, or the `mcpOAuth`-only sibling.
    static func decode(_ data: Data) -> Credentials? {
        guard
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let oauth = payload.claudeAiOauth
        else { return nil }

        return Credentials(
            accessToken: oauth.accessToken,
            refreshToken: oauth.refreshToken,
            // Stored as epoch milliseconds.
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth.subscriptionType
        )
    }
}
