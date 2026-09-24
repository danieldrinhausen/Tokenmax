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

    // MARK: - Asking Claude Code to renew

    /// Hands out scripted run results and counts the runs. No process is ever
    /// started: the coordinator is only ever given this runner.
    private final class RunnerScript: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [ClaudeTokenRenewal.RunResult]
        private var count = 0

        init(_ results: [ClaudeTokenRenewal.RunResult]) { self.results = results }

        var runs: Int { lock.withLock { count } }

        func next() -> ClaudeTokenRenewal.RunResult {
            lock.withLock {
                count += 1
                return results.isEmpty ? .unchanged : results.removeFirst()
            }
        }
    }

    private func makeRenewal(
        _ usage: UsageRefreshCoordinator,
        script: RunnerScript,
        dataSource: ClaudeDataSource = .keychain,
        clock: @escaping () -> Date = { Date(timeIntervalSince1970: 2_000_000) }
    ) -> ClaudeTokenRenewalCoordinator {
        ClaudeTokenRenewalCoordinator(
            usage: usage,
            signIn: ClaudeSignInCoordinator(usage: usage),
            settingsStore: SettingsStore(),
            claudeEnabled: { true },
            locateCLI: { URL(fileURLWithPath: "/usr/bin/true") },
            runner: { _ in script.next() },
            dataSource: { dataSource },
            now: clock,
            sleep: { _ in }
        )
    }

    /// Polls rather than yields a fixed number of times: the state sink and the
    /// CLI lookup each hop through a task, and how many hops is not the point.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A rejected token starts one renewal straight away, and not another inside the cooldown")
    func renewalRunsOnceOnRejection() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [.success(usage(at: t0)), .failure(ProviderError.tokenExpired)]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([.unchanged])
        let renewal = makeRenewal(usage, script: script)

        await usage.refresh(reason: "test", manual: true)
        await usage.refresh(reason: "test", manual: true)
        await waitUntil { script.runs == 1 && renewal.activity == .idle }
        #expect(script.runs == 1)

        await renewal.evaluate(userRequested: false)
        #expect(script.runs == 1)
        if case .coolingDown = renewal.lastSuppression {} else {
            Issue.record("expected coolingDown, got \(String(describing: renewal.lastSuppression))")
        }
    }

    @Test("Refresh asks for a renewal again inside the cooldown")
    func refreshBypassesCooldown() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [.success(usage(at: t0)), .failure(ProviderError.tokenExpired)]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([.unchanged, .unchanged])
        let renewal = makeRenewal(usage, script: script)

        await usage.refresh(reason: "test", manual: true)
        await usage.refresh(reason: "test", manual: true)
        await waitUntil { script.runs == 1 && renewal.activity == .idle }

        await renewal.evaluate(userRequested: true)
        #expect(script.runs == 2)
    }

    @Test("A renewal that took effect is followed by a fresh reading")
    func renewedRefreshes() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [
            .success(usage(at: t0)),
            .failure(ProviderError.tokenExpired),
            .success(usage(at: t0.addingTimeInterval(600))), // after Claude Code renewed
        ]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([.renewed])
        let renewal = makeRenewal(usage, script: script)

        await usage.refresh(reason: "test", manual: true)
        await usage.refresh(reason: "test", manual: true)
        await waitUntil { !usage.isAwaitingTokenRenewal }

        #expect(script.runs == 1)
        #expect(!usage.isAwaitingTokenRenewal)
        #expect(renewal.activity == .idle)
        #expect(renewal.lastSuppression == nil)
    }

    @Test("Two renewals without effect stop automatic attempts until Refresh")
    func noEffectStopsUntilRefresh() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [.success(usage(at: t0)), .failure(ProviderError.tokenExpired)]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([.unchanged, .unchanged, .unchanged])
        // A clock that jumps a full cooldown per reading, so only the no-effect
        // rule can be what stops the third automatic attempt.
        let ticks = RunnerClock()
        let renewal = makeRenewal(usage, script: script, clock: { ticks.advance() })

        await usage.refresh(reason: "test", manual: true)
        await usage.refresh(reason: "test", manual: true)
        await waitUntil { script.runs == 1 && renewal.activity == .idle }
        await renewal.evaluate(userRequested: false)
        #expect(script.runs == 2)

        await renewal.evaluate(userRequested: false)
        #expect(script.runs == 2)
        #expect(renewal.lastSuppression == .noEffect)

        await renewal.evaluate(userRequested: true)
        #expect(script.runs == 3)
    }

    @Test("Status line only mode never starts a renewal, not even from Refresh")
    func statuslineModeNeverRuns() async {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let provider = StubProvider()
        provider.outcomes = [.success(usage(at: t0)), .failure(ProviderError.tokenExpired)]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([])
        let renewal = makeRenewal(usage, script: script, dataSource: .statuslineOnly)

        await usage.refresh(reason: "test", manual: true)
        await usage.refresh(reason: "test", manual: true)
        await renewal.evaluate(userRequested: true)
        await waitUntil { renewal.lastSuppression != nil }

        #expect(script.runs == 0)
        #expect(renewal.lastSuppression == .statuslineOnly)
    }

    @Test("A healthy reading never starts a renewal")
    func healthyNeverRuns() async {
        let provider = StubProvider()
        provider.outcomes = [.success(usage(at: Date(timeIntervalSince1970: 1_000_000)))]
        let usage = makeCoordinator(provider)
        let script = RunnerScript([])
        let renewal = makeRenewal(usage, script: script)

        await usage.refresh(reason: "test", manual: true)
        await renewal.evaluate(userRequested: true)
        #expect(script.runs == 0)
    }
}

/// A clock that moves a full renewal cooldown every time it is read.
private final class RunnerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 2_000_000)

    func advance() -> Date {
        lock.withLock {
            now = now.addingTimeInterval(ClaudeTokenRenewal.cooldown + 1)
            return now
        }
    }
}
