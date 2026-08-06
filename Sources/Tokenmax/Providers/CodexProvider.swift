import Foundation

final class CodexProvider: UsageProvider {
    static let providerID = TokenmaxProvider.codex.rawValue

    let identifier = CodexProvider.providerID
    let displayName = TokenmaxProvider.codex.displayName
    private let client: CodexAppServerClient

    init(client: CodexAppServerClient = CodexAppServerClient()) { self.client = client }

    func checkAuthentication() async -> AuthenticationState {
        guard CodexCLIClient.isInstalled else { return .notInstalled }
        do {
            let (account, _) = try await client.readAccountAndLimits()
            return account.authMode == nil ? .notAuthenticated : .authenticated
        } catch { return .notAuthenticated }
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard CodexCLIClient.isInstalled else { throw ProviderError.notInstalled(displayName) }
        let (account, limits) = try await client.readAccountAndLimits()
        guard account.authMode != nil else { throw ProviderError.notAuthenticated(displayName) }
        guard account.isChatGPTManaged else {
            throw ProviderError.underlying("Codex is authenticated with an API key. It can run tasks, but this account has no ChatGPT quota meter.")
        }

        let now = Date()
        var windows: [UsageWindow] = []
        func append(_ source: CodexAppServerClient.RateLimits.Window?, id: String, kind: UsageWindowKind, label: String) {
            guard let source, source.usedPercent != nil else { return }
            windows.append(UsageWindow(
                id: id, kind: kind, label: label, usedPercent: source.usedPercent,
                resetAt: source.resetsAt, observedAt: now, source: .codexAppServer, confidence: .authoritative
            ))
        }
        // Most accounts expose a short primary and longer secondary window,
        // but the current Plus response can expose only one primary 7-day
        // limit. Its duration is authoritative: never call a 10,080-minute
        // allowance a "Session" merely because it arrived in `primary`.
        let primaryIsWeekly = (limits.primary?.durationMinutes ?? 0) >= 24 * 60
        append(
            limits.primary,
            id: primaryIsWeekly ? "codex.weekly" : "codex.session",
            kind: primaryIsWeekly ? .weekly : .session,
            label: primaryIsWeekly ? "Weekly" : "Session"
        )
        append(limits.secondary, id: "codex.weekly", kind: .weekly, label: "Weekly")
        for item in limits.additional where item.0 != "codex" {
            let label = item.1 ?? item.0
            append(item.2, id: "codex.\(item.0).session", kind: .modelSpecificWeekly, label: "\(label) session")
            append(item.3, id: "codex.\(item.0).weekly", kind: .modelSpecificWeekly, label: "\(label) weekly")
        }
        guard !windows.isEmpty else { throw ProviderError.noWindowsReturned }
        return ProviderUsage(providerID: identifier, planName: account.planName?.capitalized, windows: windows, fetchedAt: now)
    }
}
