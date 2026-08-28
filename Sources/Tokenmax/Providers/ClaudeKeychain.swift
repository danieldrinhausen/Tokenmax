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
/// per refresh tick — and a user who answers *Deny* is not asked again until
/// they click Refresh themselves.
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
        /// The user answered the consent dialog with *Deny* or dismissed it.
        /// The cache remembers this one — see `ClaudeCredentialCache` — so it
        /// must only ever mean "the user answered", never "no answer possible".
        case accessDenied
        /// macOS could not raise the dialog at all — a locked keychain during a
        /// background tick, typically. Environmental and transient, so it is
        /// kept out of `accessDenied`: remembering it as a denial would switch
        /// monitoring off because a screen was locked at the wrong moment.
        case interactionNotAllowed
        /// The endpoint rejected the token we hold and the item has not been
        /// written since, so the keychain still holds that same token. Not a
        /// failure to read — a refusal to ask a question whose answer we
        /// already have. `canSelfRenew` carries whether the rejected token had
        /// a refresh token, which is what decides between "Claude Code will fix
        /// this" and "sign in again".
        case awaitingRotation(canSelfRenew: Bool)
        case malformed
        case unexpected(OSStatus)
        /// Refused because this is a test run. See `RuntimeEnvironment`.
        case suppressedUnderTest

        var errorDescription: String? {
            switch self {
            case .notFound: "Claude Code is installed but not authenticated."
            case .accessDenied: "Tokenmax was denied access to the Claude Code keychain item."
            case .interactionNotAllowed: "The keychain could not ask for permission — it may be locked. Tokenmax will retry."
            case .awaitingRotation: "Claude Code's saved credential was rejected; Tokenmax is waiting for Claude Code to renew it."
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
    private static let cache = ClaudeCredentialCache(
        read: readFromKeychain,
        // Lets the cache wait for Claude Code to rewrite the item instead of
        // re-reading a token the endpoint already rejected. Suppressed under
        // test for the same reason the read is: the suite must not reach the
        // real item, even for an attribute nobody needs consent to see.
        itemModified: { RuntimeEnvironment.isTesting ? nil : itemModificationDate() },
        log: { Log.shared.write($0) }
    )

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

    /// Forgets a remembered denial, so the next read may ask macOS again.
    /// See `ClaudeCredentialCache.retryAfterDenial` for who may call this and
    /// why a timer never does.
    static func retryDeniedAccess() {
        cache.retryAfterDenial()
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

        // Timed so the log can say whether the consent dialog appeared: an
        // ACL-served read answers in milliseconds, a read that raised the
        // dialog blocks until the user answers. See `KeychainReadLog`.
        let started = Date()
        func log(_ outcome: KeychainReadLog.Outcome) {
            Log.shared.write(KeychainReadLog.line(
                outcome: outcome,
                elapsed: Date().timeIntervalSince(started),
                itemModified: itemModificationDate()
            ))
        }

        do {
            let credentials = try performRead()
            log(.ok)
            return credentials
        } catch let error as KeychainError {
            switch error {
            case .notFound: log(.notFound)
            case .accessDenied: log(.denied)
            case .interactionNotAllowed: log(.interactionNotAllowed)
            case .malformed: log(.malformed)
            case let .unexpected(status): log(.unexpected(status))
            // Neither can reach here: the cache throws them *instead of*
            // calling this read, so there is no read for the log to describe.
            case .awaitingRotation, .suppressedUnderTest: break
            }
            throw error
        }
    }

    /// When Claude Code last wrote the item — useful correlation for a likely
    /// token rotation, but not proof of why it changed.
    ///
    /// Attribute reads are not gated by the item's ACL, only reads of the
    /// secret data are, so this never raises a dialog. It is how each log
    /// line can carry the modification timestamp without costing a prompt.
    private static func itemModificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    private static let performRead: @Sendable () throws -> Credentials = {
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
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.accessDenied
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
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
