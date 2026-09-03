import Combine
import Foundation
import Testing

@testable import Tokenmax

/// The clock and the reading are separate objects on purpose.
///
/// They were one object until a profile of a wedged 0.1.13 showed the main
/// thread pinned at 100% in SwiftUI layout: `tick` was `@Published` on the
/// usage coordinators, `ObservableObject` invalidation is per *object* rather
/// than per property, and so a value that has to change every second rebuilt
/// every view holding `@EnvironmentObject var usage`. `GeneralSettingsView`
/// keeps that reference only to call `previewBurnGlow()` from a button, and was
/// relaying out a several-hundred-row `Form` four times a second for it.
///
/// These pin the property that fix depends on, which no amount of care in a
/// view can restore once the clock publishes from the shared object again.
@Suite("Countdown clock")
@MainActor
struct CountdownClockTests {
    private final class StubProvider: UsageProvider, @unchecked Sendable {
        let identifier = "claude-code"
        let displayName = "Claude Code"

        func fetchUsage() async throws -> ProviderUsage {
            ProviderUsage(
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

    private func makeCoordinator() -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(
            provider: StubProvider(),
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// The whole point of the split. A second passing is not news to anything
    /// that shows a reading rather than a countdown.
    @Test("A clock tick does not invalidate views observing the usage reading")
    func tickDoesNotInvalidateUsage() async {
        let coordinator = makeCoordinator()
        coordinator.start()
        await settle()
        // Past the launch refresh, so only the tick is under test.
        coordinator.advance(to: Date())

        var invalidations = 0
        let token = coordinator.objectWillChange.sink { _ in invalidations += 1 }
        defer { token.cancel() }

        for second in 1...5 {
            coordinator.advance(to: Date().addingTimeInterval(TimeInterval(second)))
        }

        #expect(invalidations == 0)
    }

    /// `stop()` used to invalidate a per-coordinator tick timer, so a provider
    /// the user switched off cost nothing. Driving the clock from outside must
    /// not quietly give that back.
    @Test("A stopped provider ignores the clock")
    func stoppedProviderIgnoresTheClock() async {
        let coordinator = makeCoordinator()
        coordinator.start()
        await settle()
        coordinator.stop()

        var invalidations = 0
        let token = coordinator.objectWillChange.sink { _ in invalidations += 1 }
        defer { token.cancel() }

        coordinator.advance(to: Date().addingTimeInterval(3600))

        #expect(invalidations == 0)
        #expect(coordinator.burnOpportunity == nil)
    }

    /// The parent forwards every child change to the views, which is correct
    /// for a reading and was catastrophic for a clock: one tick per provider
    /// arrived as a forwarded `objectWillChange` *and* as the parent's own
    /// mirrored `@Published tick`, so a settings pane rebuilt four times a
    /// second. The forward has to survive; the tick must not travel through it.
    @Test("A clock tick does not reach views through the provider coordinator")
    func tickDoesNotReachTheParent() async {
        let usage = ProviderUsageCoordinator(settingsStore: SettingsStore())
        await settle()

        var invalidations = 0
        let token = usage.objectWillChange.sink { _ in invalidations += 1 }
        defer { token.cancel() }

        for second in 1...5 {
            let now = Date().addingTimeInterval(TimeInterval(second))
            usage.claude.advance(to: now)
            usage.codex.advance(to: now)
        }

        #expect(invalidations == 0)
    }

    @Test("Starting the clock twice does not double up the tick")
    func startIsIdempotent() {
        let clock = CountdownClock()
        clock.start()
        clock.start()
        clock.stop()
        clock.stop()
    }
}
