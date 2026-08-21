import Foundation

/// Composes the two real sources of Claude quota data.
///
/// Primary is the OAuth usage endpoint (undocumented, but pollable at any time
/// and exact). Fallback is the statusline shim (documented, but only fresh
/// while a session is running). Per-window, whichever has the better
/// (confidence, freshness) pair wins — so a live session can top up the weekly
/// number even if the network call failed.
final class ClaudeCodeProvider: UsageProvider {
    static let providerID = "claude-code"

    let identifier = ClaudeCodeProvider.providerID
    let displayName = "Claude Code"

    private let client: ClaudeOAuthUsageClient
    private let readStatusline: @Sendable () -> (StatuslinePayload, Date)?
    private let readCredentials: @Sendable () throws -> ClaudeKeychain.Credentials
    private let invalidateCredentials: @Sendable () -> Void
    private let retryDeniedAccess: @Sendable () -> Void
    private let cliInstalled: @Sendable () -> Bool
    private let cliVersion: @Sendable () -> String

    init(
        client: ClaudeOAuthUsageClient = ClaudeOAuthUsageClient(),
        readStatusline: @escaping @Sendable () -> (StatuslinePayload, Date)? = { StatuslineUsageReader.read() },
        readCredentials: @escaping @Sendable () throws -> ClaudeKeychain.Credentials = { try ClaudeKeychain.readCredentials() },
        invalidateCredentials: @escaping @Sendable () -> Void = { ClaudeKeychain.invalidateCache() },
        retryDeniedAccess: @escaping @Sendable () -> Void = { ClaudeKeychain.retryDeniedAccess() },
        cliInstalled: @escaping @Sendable () -> Bool = { ClaudeCLIClient.isInstalled },
        cliVersion: @escaping @Sendable () -> String = { ClaudeCLIClient.version() }
    ) {
        self.client = client
        self.readStatusline = readStatusline
        self.readCredentials = readCredentials
        self.invalidateCredentials = invalidateCredentials
        self.retryDeniedAccess = retryDeniedAccess
        self.cliInstalled = cliInstalled
        self.cliVersion = cliVersion
    }

    /// Forgets a remembered keychain denial, so the next read may raise the
    /// consent dialog again. Called by the refresh coordinator on a *manual*
    /// refresh only — the popover's denied state says "click Refresh", and
    /// that click has to be the thing that re-opens the question.
    func retryDeniedKeychainAccess() {
        retryDeniedAccess()
    }

    /// Forwards the OAuth client's rate-limit floor. See
    /// `ClaudeOAuthUsageClient.nextRequestAllowedAt`.
    var nextRequestAllowedAt: Date {
        get async { await client.nextRequestAllowedAt }
    }

    func checkAuthentication() async -> AuthenticationState {
        guard cliInstalled() else { return .notInstalled }
        do {
            let credentials = try readCredentials()
            return credentials.isExpired ? .needsReauthentication : .authenticated
        } catch ClaudeKeychain.KeychainError.notFound {
            return .notAuthenticated
        } catch ClaudeKeychain.KeychainError.accessDenied {
            return .accessDenied
        } catch {
            return .notAuthenticated
        }
    }

    func fetchUsage() async throws -> ProviderUsage {
        guard cliInstalled() else { throw ProviderError.notInstalled(displayName) }

        let credentials = try loadCredentials()

        var planName = credentials.subscriptionType.map(Self.prettyPlanName)
        var windows: [UsageWindow] = []
        var extraUsageEnabled: Bool?
        var primaryError: Error?

        do {
            let (response, fetchedAt) = try await client.fetch(
                accessToken: credentials.accessToken,
                cliVersion: cliVersion()
            )
            windows = Self.windows(from: response, observedAt: fetchedAt)
            // Left nil when the primary call fails: the statusline fallback
            // knows nothing about extra usage, and reporting "off" from silence
            // is exactly the mistake that would let the opener spend money.
            extraUsageEnabled = response.extraUsage?.isEnabled
        } catch {
            primaryError = error
            // A rejected token is the one signal that the credentials we hold
            // are behind Claude Code's rotation, so drop them and let the next
            // refresh read the keychain again. Retrying here instead would be
            // worse than useless: the client's 180s floor was just armed by the
            // request that failed, so an immediate second call returns
            // `.rateLimited` and would replace a precise "token expired" state
            // with a generic error.
            if let error = error as? UsageClientError, case .unauthorized = error {
                invalidateCredentials()
                Log.shared.write("provider: token rejected, dropped cached credentials")
            }
            Log.shared.write("provider: oauth source failed: \(error.localizedDescription)")
        }

        // Merge in the documented fallback, which can also fill windows the
        // primary omitted.
        if let (payload, observedAt) = readStatusline() {
            let fallback = StatuslineUsageReader.windows(from: payload, observedAt: observedAt)
            windows = Self.merge(primary: windows, fallback: fallback)
            if planName == nil { planName = nil }
        }

        guard !windows.isEmpty else {
            if let primaryError {
                throw Self.mapped(primaryError, credentials: credentials)
            }
            throw ProviderError.noWindowsReturned
        }

        // Report when the data was actually *observed*, not when we asked for
        // it. Inside the 180s floor the client legitimately replays a cached
        // response, and stamping that with `Date()` would make stale data look
        // freshly fetched in the popover and defeat the staleness check.
        let observedAt = windows.map(\.observedAt).max() ?? Date()

        return ProviderUsage(
            providerID: identifier,
            planName: planName,
            windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
            fetchedAt: observedAt,
            extraUsageEnabled: extraUsageEnabled
        )
    }

    /// Never refreshes the token itself — racing Claude Code's own refresh
    /// risks invalidating the refresh token.
    ///
    /// A locally-computed expiry is **not** grounds for refusing to try. The
    /// clock check is only a hint: the endpoint may still accept the token, and
    /// if it does not, the 401 lands in `mapped` and produces the same state
    /// anyway. Bailing out early could only ever turn a working request into an
    /// error.
    ///
    /// This used to read twice when the first read looked expired, to pick up a
    /// rotation. `ClaudeCredentialCache` now does that where it belongs — it
    /// never hands out a token past its own expiry — and the second read here
    /// only ever bought a second consent dialog in the same tick.
    private func loadCredentials() throws -> ClaudeKeychain.Credentials {
        do {
            return try readCredentials()
        } catch let error as ClaudeKeychain.KeychainError {
            switch error {
            case .notFound: throw ProviderError.notAuthenticated(displayName)
            case .accessDenied: throw ProviderError.accessDenied
            // Transient by definition — the dialog could not be shown, so
            // nobody said no. Reported as an ordinary failure that keeps the
            // last good reading, never as the denied state, which now carries
            // a backoff the user would have to clear by hand.
            case .interactionNotAllowed, .malformed, .unexpected, .suppressedUnderTest:
                throw ProviderError.underlying(error.localizedDescription)
            }
        }
    }

    /// A rejected token means "sign in again" only when there is no refresh
    /// token left to rotate it with. Otherwise Claude Code fixes this by itself
    /// the next time it runs, and telling the user to re-authenticate sends
    /// them through an OAuth flow they did not need.
    private static func mapped(_ error: Error, credentials: ClaudeKeychain.Credentials) -> Error {
        if let error = error as? UsageClientError, case .unauthorized = error {
            return credentials.refreshToken == nil
                ? ProviderError.needsReauthentication
                : ProviderError.tokenExpired
        }
        return ProviderError.underlying(error.localizedDescription)
    }

    static func prettyPlanName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro": "Pro"
        case "max": "Max"
        case "max_5x": "Max 5×"
        case "max_20x": "Max 20×"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: raw.capitalized
        }
    }

    static func windows(from response: OAuthUsageResponse, observedAt: Date) -> [UsageWindow] {
        var result: [UsageWindow] = []

        func append(
            _ window: OAuthUsageResponse.Window?,
            id: String,
            kind: UsageWindowKind,
            label: String
        ) {
            guard let window, let utilization = window.utilization else { return }
            result.append(UsageWindow(
                id: id,
                kind: kind,
                label: label,
                usedPercent: utilization,
                resetAt: window.resetsAt,
                observedAt: observedAt,
                source: .claudeOAuth,
                confidence: .authoritative
            ))
        }

        append(response.fiveHour, id: "claude.session", kind: .session, label: "Session")
        append(response.sevenDay, id: "claude.weekly", kind: .weekly, label: "Weekly")
        append(response.sevenDayOpus, id: "claude.weekly.opus", kind: .modelSpecificWeekly, label: "Weekly (Opus)")
        append(response.sevenDaySonnet, id: "claude.weekly.sonnet", kind: .modelSpecificWeekly, label: "Weekly (Sonnet)")

        return result
    }

    /// Keeps the better window per id: higher confidence wins, and ties break
    /// on whichever was observed more recently.
    static func merge(primary: [UsageWindow], fallback: [UsageWindow]) -> [UsageWindow] {
        var byID: [String: UsageWindow] = [:]
        for window in primary + fallback {
            guard let existing = byID[window.id] else {
                byID[window.id] = window
                continue
            }
            if window.confidence.rank > existing.confidence.rank {
                byID[window.id] = window
            } else if window.confidence.rank == existing.confidence.rank,
                      window.observedAt > existing.observedAt
            {
                byID[window.id] = window
            }
        }
        return Array(byID.values)
    }
}

extension UsageWindowKind {
    var sortOrder: Int {
        switch self {
        case .session: 0
        case .weekly: 1
        case .modelSpecificWeekly: 2
        }
    }
}
