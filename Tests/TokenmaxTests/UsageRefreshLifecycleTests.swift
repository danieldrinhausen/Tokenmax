import Foundation
import Testing

@testable import Tokenmax

/// A provider the user has switched off must actually stop polling. Before
/// `stop()` existed there was no way to tear down the one-second tick timer, the
/// repeating refresh, or the wake observer — they ran for the life of the app.
///
/// These assert on observable state (did a fetch land?) rather than on timer
/// timing, which is not something a test can wait on reliably.
@Suite("Usage refresh lifecycle")
@MainActor
struct UsageRefreshLifecycleTests {
    /// Counts fetches so a test can tell "did not refresh" from "refreshed with
    /// the same answer". Deliberately a near-copy of the stub in
    /// `AwaitingTokenRenewalTests` rather than a shared one — hoisting it would
    /// disturb a passing suite for no benefit here.
    private final class CountingProvider: UsageProvider, @unchecked Sendable {
        let identifier = "claude-code"
        let displayName = "Claude Code"
        private(set) var fetchCount = 0

        func fetchUsage() async throws -> ProviderUsage {
            fetchCount += 1
            return ProviderUsage(
                providerID: identifier,
                planName: "Pro",
                windows: [UsageWindow(
                    id: "claude.session", kind: .session, label: "Session",
                    usedPercent: 10, resetAt: nil, observedAt: Date(),
                    source: .claudeOAuth, confidence: .authoritative
                )],
                fetchedAt: Date()
            )
        }

        func checkAuthentication() async -> AuthenticationState { .authenticated }
    }

    private func makeCoordinator(_ provider: CountingProvider) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            // A path nothing else writes, so the suite never inherits or
            // clobbers a real snapshot.
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )
    }

    /// `start()` kicks off a launch refresh on a detached task; let it land.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("Stopping before starting, and stopping twice, are both safe")
    func stopIsIdempotent() {
        let coordinator = makeCoordinator(CountingProvider())

        coordinator.stop()
        coordinator.start()
        coordinator.stop()
        coordinator.stop()

        #expect(!coordinator.isRefreshing)
    }

    @Test("Starting twice does not double up the polling")
    func startIsIdempotent() async {
        let provider = CountingProvider()
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        coordinator.start()
        await settle()

        #expect(provider.fetchCount == 1)
    }

    /// The bug this pins: `popoverOpened()` called `scheduleRefreshTimer()`
    /// unconditionally, so opening the popover would rebuild the refresh timer
    /// of a provider that had been switched off — and fetch on the spot.
    @Test("A stopped coordinator does not refresh when the popover opens")
    func stoppedCoordinatorIgnoresPopover() async {
        let provider = CountingProvider()
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        await settle()
        let afterStart = provider.fetchCount

        coordinator.stop()
        coordinator.popoverOpened()
        coordinator.popoverClosed()
        await settle()

        #expect(provider.fetchCount == afterStart)
    }

    @Test("Starting again after a stop resumes polling")
    func restartResumes() async {
        let provider = CountingProvider()
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        await settle()
        coordinator.stop()

        coordinator.start()
        await settle()

        #expect(provider.fetchCount == 2)
    }

    /// Switching a provider back on should show its last reading immediately
    /// rather than flash "Never updated" while the first fetch runs.
    @Test("Stopping keeps the last good reading on screen")
    func stopKeepsLastReading() async {
        let provider = CountingProvider()
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        await settle()
        #expect(coordinator.state.snapshot != nil)

        coordinator.stop()
        #expect(coordinator.state.snapshot != nil)
    }
}
