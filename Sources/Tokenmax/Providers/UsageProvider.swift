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
    /// The access token was rejected but a refresh token is still on file, so
    /// Claude Code will rotate it on its own the next time it runs. Transient,
    /// self-healing, and explicitly *not* a reason to make the user sign in.
    case tokenExpired
    /// The access token was rejected and there is nothing left to refresh it
    /// with. This one really does need a sign-in.
    case needsReauthentication
    case noWindowsReturned
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(name): "\(name) is not installed."
        case let .notAuthenticated(name): "\(name) is installed but not authenticated."
        case .accessDenied: "Tokenmax needs keychain access to read Claude usage."
        case .tokenExpired: "Claude Code's access token expired; it refreshes on next use."
        case .needsReauthentication: "Claude Code needs to be re-authenticated."
        case .noWindowsReturned: "No quota windows were returned."
        case let .underlying(message): message
        }
    }
}
