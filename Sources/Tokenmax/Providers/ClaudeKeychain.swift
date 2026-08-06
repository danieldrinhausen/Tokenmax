import Foundation
import Security

/// Reads the OAuth credentials Claude Code stores in the login keychain.
///
/// The item is owned by the `claude` binary, so the first read from Tokenmax
/// triggers a macOS consent prompt. That grant is bound to our code signature —
/// with ad-hoc signing the signature changes on every rebuild, so the prompt
/// reappears after each `make install` during development. It is genuinely
/// one-time for a stable installed build.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

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

    static func readCredentials() throws -> Credentials {
        // Guarded here rather than at the call sites because the call sites are
        // not the point: anything constructed with default arguments reaches
        // this function, and the app builds several such objects at launch.
        // One guard at the boundary is the only version that stays true as
        // callers are added.
        guard !RuntimeEnvironment.isTesting else { throw KeychainError.suppressedUnderTest }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
