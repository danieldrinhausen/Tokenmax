import Foundation

enum AuthenticationState: Sendable, Equatable {
    case authenticated
    case notInstalled
    case notAuthenticated
    case accessDenied
    case needsReauthentication
}

protocol UsageProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func fetchUsage() async throws -> ProviderUsage
    func checkAuthentication() async -> AuthenticationState
}

enum ProviderError: Error, LocalizedError, Equatable {
    /// Carries the provider's display name because this error is the one both
    /// providers raise. Hardcoding "Claude Code" here meant a missing `codex`
    /// binary logged "Claude Code is not installed." — which sends you looking
    /// at a CLI that was installed and working the whole time.
    case notInstalled(String)
    case notAuthenticated(String)
    case accessDenied
    /// The saved access token was rejected but a refresh token is still on
    /// file. A running Claude Code session may still have its own live
    /// connection; it writes a replacement here only when it renews its login.
    /// Transient, self-healing, and explicitly *not* a reason to make the user
    /// sign in.
    case tokenExpired
    /// The access token was rejected and there is nothing left to refresh it
    /// with. This one really does need a sign-in.
    case needsReauthentication
    case noWindowsReturned
    /// The data source is statusline-only and the shim has not written a
    /// payload yet. A distinct case rather than `noWindowsReturned` because
    /// the fix is different: nothing is broken, a Claude Code session just has
    /// to answer once — and the keychain must not be consulted instead.
    case statuslineNoData
    /// Signed in with an API key rather than a subscription. The agent still
    /// runs, but there is no plan allowance to meter and the work is billed per
    /// token — which is why this is a distinct case rather than free text: the
    /// queue has to refuse on it, and matching on a message string to do that
    /// would break the first time the wording changed.
    case apiKeyConfigured(String)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(name): "\(name) is not installed."
        case let .notAuthenticated(name): "\(name) is installed but not authenticated."
        case .accessDenied: "Tokenmax needs keychain access to read Claude usage."
        case .tokenExpired:
            "Claude Code's saved credential was rejected; it normally renews when Claude Code needs a new connection."
        case .needsReauthentication: "Claude Code needs to be re-authenticated."
        case .noWindowsReturned: "No quota windows were returned."
        case .statuslineNoData:
            "No status line reading yet. Usage appears once a Claude Code session responds; the keychain is never consulted in this mode."
        case let .apiKeyConfigured(name):
            "\(name) is authenticated with an API key. It can run tasks, but this account has no subscription quota meter."
        case let .underlying(message): message
        }
    }
}
