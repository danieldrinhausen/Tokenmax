import Foundation
import Security

/// Reads the OAuth credentials Claude Code stores in the login keychain.
///
/// The item is owned by the `claude` binary, so the first read from Tokenmax
/// triggers a macOS consent prompt. That grant is bound to our code signature,
/// and because the bundle carries no Team ID macOS can only key it to the raw
/// cdhash — which changes with every build. So the prompt returns once per
/// binary: once per rebuild while developing, once per release a user installs.
/// Only an Apple-anchored certificate would change that; see
/// `docs/TROUBLESHOOTING.md`.
///
/// What *is* fixed here is how often it can be asked. Every read is served
/// through `ClaudeCredentialCache`, so a user who answers the dialog with
/// *Allow* rather than *Always Allow* meets it once per launch instead of once
/// per refresh tick.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let subscriptionType: String?

        var isExpired: Bool { isExpired(at: Date()) }

        /// Takes the clock as a parameter so the cache can be tested without
        /// waiting for a token to age out.
        func isExpired(at date: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= date
        }
    }

    enum KeychainError: Error, LocalizedError {
        case notFound
        case accessDenied
        case malformed
        case unexpected(OSStatus)
        /// Refused because this is a test run. See `RuntimeEnvironment`.
        case suppressedUnderTest

        var errorDescription: String? {
            switch self {
            case .notFound: "Claude Code is installed but not authenticated."
            case .accessDenied: "Tokenmax was denied access to the Claude Code keychain item."
            case .malformed: "The Claude Code credentials could not be read."
            case let .unexpected(status): "Keychain error \(status)."
            case .suppressedUnderTest: "Keychain access is refused during tests."
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

        let claudeAiOauth: OAuth
    }

    /// The one cache every caller shares.
    ///
    /// Shared rather than per-object on purpose: the app builds several
    /// credential readers at launch — the usage provider and the model catalog
    /// among them — and a cache per object would mean a dialog per object,
    /// which is the bug in miniature.
    private static let cache = ClaudeCredentialCache(read: readFromKeychain)

    /// Serves the shared cache, reading the keychain only when it has nothing
    /// usable. See `ClaudeCredentialCache` for what that means.
    static func readCredentials() throws -> Credentials {
        try cache.credentials()
    }

    /// Drops the cached credentials, so the next read goes back to the keychain.
    ///
    /// The one caller that should reach for this is a 401 from the usage
    /// endpoint: a rejected token is the only reliable evidence that Claude
    /// Code rotated the item since we read it.
    static func invalidateCache() {
        cache.invalidate()
    }

    private static let readFromKeychain: @Sendable () throws -> Credentials = {
        // Guarded here rather than at the call sites because the call sites are
        // not the point: anything constructed with default arguments reaches
        // this function, and the app builds several such objects at launch.
        // One guard at the boundary is the only version that stays true as
        // callers are added.
        //
        // Guarded *inside* the cache's read rather than in front of it so a
        // test run can never leave real credentials sitting in the cache.
        guard !RuntimeEnvironment.isTesting else { throw KeychainError.suppressedUnderTest }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeKeychain.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeychainError.accessDenied
        default:
            throw KeychainError.unexpected(status)
        }

        guard let data = result as? Data else { throw KeychainError.malformed }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let oauth = payload.claudeAiOauth
            return Credentials(
                accessToken: oauth.accessToken,
                refreshToken: oauth.refreshToken,
                // Stored as epoch milliseconds.
                expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                subscriptionType: oauth.subscriptionType
            )
        } catch {
            throw KeychainError.malformed
        }
    }
}
