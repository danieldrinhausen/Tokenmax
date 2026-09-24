import Foundation

/// Cursor's included usage for the current billing cycle. Usage only: Cursor
/// is never a task runner.
final class CursorProvider: UsageProvider {
    static let providerID = TokenmaxProvider.cursor.rawValue

    let identifier = CursorProvider.providerID
    let displayName = TokenmaxProvider.cursor.displayName
    private let client: CursorUsageClient
    private let stateDatabase: URL

    init(client: CursorUsageClient = CursorUsageClient(), stateDatabase: URL = FileLocations.cursorStateDatabase) {
        self.client = client
        self.stateDatabase = stateDatabase
    }

    func checkAuthentication() async -> AuthenticationState {
        do {
            _ = try CursorStateStore.read(from: stateDatabase)
            return .authenticated
        } catch CursorStateError.missingDatabase {
            return .notInstalled
        } catch {
            return .notAuthenticated
        }
    }

    func fetchUsage() async throws -> ProviderUsage {
        let credentials: CursorCredentials
        do {
            credentials = try CursorStateStore.read(from: stateDatabase)
        } catch CursorStateError.missingDatabase {
            throw ProviderError.notInstalled(displayName)
        } catch CursorStateError.signedOut {
            throw ProviderError.notAuthenticated(displayName)
        } catch let CursorStateError.unreadable(message) {
            throw ProviderError.underlying("Tokenmax could not read Cursor's sign-in: \(message)")
        }

        let summary: CursorUsageSummary
        let fetchedAt: Date
        do {
            (summary, fetchedAt) = try await client.fetch(credentials: credentials)
        } catch CursorUsageClientError.unauthorized {
            // Cursor renews its own sign-in when it runs; Tokenmax never does.
            throw ProviderError.notAuthenticated(displayName)
        } catch let error as CursorUsageClientError {
            throw ProviderError.underlying(error.localizedDescription)
        }

        let windows = Self.windows(from: summary, observedAt: fetchedAt)
        guard !windows.isEmpty else { throw ProviderError.noWindowsReturned }
        return ProviderUsage(
            providerID: identifier,
            planName: Self.planName(summary.membershipType ?? credentials.membershipType),
            windows: windows,
            fetchedAt: fetchedAt,
            extraUsageEnabled: summary.individualUsage?.onDemand?.enabled
        )
    }

    /// Two meters over the one billing cycle, both resetting when it ends.
    ///
    /// Total first because it is the headline Cursor itself shows; API second
    /// because it is the one that runs out — named models cost far more of the
    /// allowance than Auto does, so it can sit at 90% while the total sits at
    /// 10%. Auto's own percentage is left out: it is the cheap remainder of the
    /// total and a third meter would say nothing the first does not.
    static func windows(from summary: CursorUsageSummary, observedAt: Date) -> [UsageWindow] {
        let plan = summary.individualUsage?.plan
        var windows: [UsageWindow] = []
        func append(_ usedPercent: Double?, id: String, label: String) {
            guard let usedPercent else { return }
            windows.append(UsageWindow(
                id: id, kind: .billingCycle, label: label,
                usedPercent: max(0, min(100, usedPercent)), resetAt: summary.billingCycleEnd,
                observedAt: observedAt, source: .cursorDashboard, confidence: .authoritative
            ))
        }
        append(plan?.totalPercentUsed, id: "cursor.total", label: "Total")
        append(plan?.apiPercentUsed, id: "cursor.api", label: "API")
        return windows
    }

    /// `pro` → `Pro`, `pro_plus` → `Pro Plus`. Cursor's values are internal
    /// identifiers, not display names.
    static func planName(_ membership: String?) -> String? {
        guard let membership, !membership.isEmpty else { return nil }
        return membership.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
