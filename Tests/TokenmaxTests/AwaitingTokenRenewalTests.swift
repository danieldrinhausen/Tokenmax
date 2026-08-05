import Foundation
import Testing

@testable import Tokenmax

/// The deadlock this guards against, in the order it actually happened:
/// the access token expires, every network call 401s, the OAuth client replays
/// its cached response inside the 180s floor, and a rate-limit lands on top.
/// Either of the last two used to clear `isAwaitingTokenRenewal`, which is the
/// only thing that lets the session opener run on stale data — and the opener
/// is the one action that would have renewed the token.
@Suite("Awaiting token renewal")
@MainActor
struct AwaitingTokenRenewalTests {
    /// Returns whatever it is told to, so the coordinator can be walked through
    /// an exact sequence of outcomes.
    private final class StubProvider: UsageProvider, @unchecked Sendable {
        let identifier = "claude-code"
        let displayName = "Claude Code"
        var outcomes: [Result<ProviderUsage, Error>] = []

        func fetchUsage() async throws -> ProviderUsage {
            guard !outcomes.isEmpty else { throw ProviderError.underlying("no outcome queued") }
            return try outcomes.removeFirst().get()
        }

        func checkAuthentication() async -> AuthenticationState { .authenticated }
    }

    private func usage(at observedAt: Date) -> ProviderUsage {
        ProviderUsage(
            providerID: "claude-code",
            planName: "Pro",
            windows: [UsageWindow(
                id: "claude.session", kind: .session, label: "Session",
                usedPercent: 0, resetAt: nil, observedAt: observedAt,
                source: .claudeOAuth, confidence: .authoritative
            )],
            fetchedAt: observedAt
        )
    }

    private func makeCoordinator(_ provider: StubProvider) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            // A path nothing else writes, so the suite never inherits or
            // clobbers a real snapshot.
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )
    }

    @Test("A cached replay does not clear a pending token renewal")
    func cachedReplayKeepsAwaiting() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [
            .success(usage(at: t0)),              // a good reading
            .failure(ProviderError.tokenExpired), // token expires
            .success(usage(at: t0)),              // the 180s floor replays it
        ]
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "test", manual: true)
        #expect(!coordinator.isAwaitingTokenRenewal)

        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)

        // The replay carries the *same* observation, so nothing was renewed.
        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)
        #expect(coordinator.state.snapshot != nil)
    }

    /// The failure that actually broke it: a rate-limit — including Tokenmax's
    /// own request floor firing with an empty cache — used to overwrite
    /// `.tokenExpired` with `.unavailable` and silently disarm the opener.
    @Test("A rate-limit on top does not clear a pending token renewal")
    func rateLimitKeepsAwaiting() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [
            .success(usage(at: t0)),
            .failure(ProviderError.tokenExpired),
            .failure(ProviderError.underlying("Anthropic rate-limited the usage request.")),
        ]
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "test", manual: true)
        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)

        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)
        // And the diagnosis on screen stays the real blocker rather than being
        // relabelled as a generic outage.
        if case .tokenExpired = coordinator.state {} else {
            Issue.record("expected .tokenExpired, got \(coordinator.state)")
        }
    }

    @Test("A genuinely newer reading clears it")
    func newObservationClearsAwaiting() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [
            .success(usage(at: t0)),
            .failure(ProviderError.tokenExpired),
            .success(usage(at: t0.addingTimeInterval(60))), // Claude rotated it
        ]
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "test", manual: true)
        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)

        await coordinator.refresh(reason: "test", manual: true)
        #expect(!coordinator.isAwaitingTokenRenewal)
        if case .loaded = coordinator.state {} else {
            Issue.record("expected .loaded, got \(coordinator.state)")
        }
    }

    /// A run of Claude Code cannot rotate a refresh token that is gone, so the
    /// opener must not believe it has a recovery available.
    @Test("Needing a full sign-in is not an awaited renewal")
    func reauthenticationClearsAwaiting() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [
            .success(usage(at: t0)),
            .failure(ProviderError.tokenExpired),
            .failure(ProviderError.needsReauthentication),
        ]
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "test", manual: true)
        await coordinator.refresh(reason: "test", manual: true)
        #expect(coordinator.isAwaitingTokenRenewal)

        await coordinator.refresh(reason: "test", manual: true)
        #expect(!coordinator.isAwaitingTokenRenewal)
    }

    /// The end of the chain: with the fact preserved, the opener is allowed to
    /// spend on the last good reading and so can renew the token itself.
    @Test("The opener may run on stale data while awaiting renewal")
    func openerAllowance() {
        var settings = SessionOpenerSettings()
        settings.enabled = true

        let input = SessionOpener.Input(
            settings: settings,
            sessionWindow: nil,
            weeklyWindow: nil,
            isStale: true,
            awaitingTokenRenewal: true,
            dataAge: 3600
        )
        #expect(SessionOpener.mayOpenOnStaleData(input))

        var notAwaiting = input
        notAwaiting.awaitingTokenRenewal = false
        #expect(!SessionOpener.mayOpenOnStaleData(notAwaiting))

        // The age bound still holds: past one session window the weekly figure
        // the reading carries stops bounding anything.
        var tooOld = input
        tooOld.dataAge = SessionOpener.maxStaleAgeAwaitingTokenRenewal + 1
        #expect(!SessionOpener.mayOpenOnStaleData(tooOld))
    }
}
