import AppKit
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

    @Test("Closing one usage surface keeps foreground cadence while another remains open")
    func independentSurfacesKeepForegroundCadence() {
        let coordinator = makeCoordinator(CountingProvider())

        coordinator.surfaceOpened(.popover)
        coordinator.surfaceOpened(.sideNotch)
        coordinator.surfaceClosed(.popover)
        #expect(coordinator.usesForegroundRefreshCadence)

        coordinator.surfaceClosed(.sideNotch)
        #expect(!coordinator.usesForegroundRefreshCadence)
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

    /// Holds its second fetch open until released, so a test can switch the
    /// provider off while a refresh is in flight.
    private final class HeldProvider: UsageProvider, @unchecked Sendable {
        let identifier = "claude-code"
        let displayName = "Claude Code"
        private let lock = NSLock()
        private var fetchCount = 0
        private var gate: CheckedContinuation<Void, Never>?

        var isHolding: Bool { lock.withLock { gate != nil } }

        func release() {
            lock.withLock {
                gate?.resume()
                gate = nil
            }
        }

        func fetchUsage() async throws -> ProviderUsage {
            let count = lock.withLock { () -> Int in
                fetchCount += 1
                return fetchCount
            }
            if count > 1 {
                await withCheckedContinuation { continuation in
                    lock.withLock { gate = continuation }
                }
            }
            return ProviderUsage(
                providerID: identifier,
                planName: count > 1 ? "Late" : "Pro",
                windows: [],
                fetchedAt: Date()
            )
        }

        func checkAuthentication() async -> AuthenticationState { .authenticated }
    }

    /// Found by review: `stop()` cancelled only the launch refresh. A timer
    /// tick or a wake already in flight landed afterwards and wrote a reading
    /// to a provider the user had just switched off.
    @Test("A refresh in flight when the provider is switched off does not land")
    func inFlightRefreshDoesNotLandAfterStop() async throws {
        let provider = HeldProvider()
        let coordinator = UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )

        coordinator.start()
        await settle()
        #expect(coordinator.state.snapshot?.planName == "Pro")

        let tick = Task { await coordinator.refresh(reason: "timer") }
        for _ in 0..<500 where !provider.isHolding {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(provider.isHolding)

        coordinator.stop()
        provider.release()
        await tick.value

        #expect(coordinator.state.snapshot?.planName == "Pro")
    }

    // MARK: - Cancellation, queued refreshes and overlap

    /// Holds the first fetch until released, can fail on demand, and records how
    /// many fetches ran at once. The fetch honours cancellation the way a real
    /// URLSession call does, so a refresh that gets cancelled really throws.
    private final class GatedProvider: UsageProvider, @unchecked Sendable {
        let identifier = "claude-code"
        let displayName = "Claude Code"
        private let lock = NSLock()
        private var count = 0
        private var active = 0
        private var peak = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var holdFirst: Bool
        private var failure: Error?

        init(holdFirst: Bool, failure: Error? = nil) {
            self.holdFirst = holdFirst
            self.failure = failure
        }

        var fetchCount: Int { lock.withLock { count } }
        var maxConcurrent: Int { lock.withLock { peak } }
        var isHolding: Bool { lock.withLock { gate != nil } }

        func release() {
            lock.withLock {
                gate?.resume()
                gate = nil
                holdFirst = false
            }
        }

        func fail(with error: Error?) { lock.withLock { failure = error } }

        func fetchUsage() async throws -> ProviderUsage {
            let (number, hold, error) = lock.withLock { () -> (Int, Bool, Error?) in
                count += 1
                active += 1
                peak = max(peak, active)
                return (count, holdFirst && count == 1, failure)
            }
            defer { lock.withLock { active -= 1 } }
            if hold {
                await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
            }
            try Task.checkCancellation()
            if let error { throw error }
            return ProviderUsage(
                providerID: identifier, planName: "Fetch \(number)", windows: [], fetchedAt: Date()
            )
        }

        func checkAuthentication() async -> AuthenticationState { .authenticated }
    }

    private func makeCoordinator(_ provider: some UsageProvider) -> UsageRefreshCoordinator {
        UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
    }

    private func isUnavailable(_ state: UsageState) -> Bool {
        if case .unavailable = state { return true }
        return false
    }

    /// The bug: opening the popover during the launch fetch cancelled it, the
    /// cancelled call was counted as a failure, and the user saw "cancelled".
    @Test("Opening the popover during the launch fetch lets that fetch finish instead of cancelling it")
    func surfaceOpenDoesNotCancelInFlightRefresh() async throws {
        let provider = GatedProvider(holdFirst: true)
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        try await waitUntil { provider.isHolding }
        coordinator.popoverOpened()
        provider.release()
        try await waitUntil { coordinator.state.snapshot != nil }

        #expect(coordinator.state.snapshot?.planName == "Fetch 1")
        #expect(!isUnavailable(coordinator.state))
        // The popover's own refresh was redundant with the one already running.
        #expect(provider.fetchCount == 1)
        coordinator.stop()
    }

    @Test("A cancelled fetch is not a failure: state is untouched and no backoff follows")
    func cancellationIsSilent() async throws {
        let provider = GatedProvider(holdFirst: false, failure: CancellationError())
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "first")
        #expect(coordinator.state.snapshot == nil)
        #expect(!isUnavailable(coordinator.state))

        // No backoff was armed, so the very next automatic refresh goes through.
        provider.fail(with: nil)
        await coordinator.refresh(reason: "second")
        #expect(coordinator.state.snapshot?.planName == "Fetch 2")
    }

    @Test("A real failure still arms the backoff that a cancellation does not")
    func failureStillBacksOff() async {
        let provider = GatedProvider(holdFirst: false, failure: URLError(.timedOut))
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "first")
        #expect(isUnavailable(coordinator.state))

        provider.fail(with: nil)
        await coordinator.refresh(reason: "second")
        #expect(provider.fetchCount == 1)
    }

    @Test("Cancellation is recognised through URLError, NSError and CancellationError, and only those")
    func recognisesCancellation() {
        #expect(CancellationError().isCancellation)
        #expect(URLError(.cancelled).isCancellation)
        #expect(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled).isCancellation)
        #expect(!URLError(.timedOut).isCancellation)
        #expect(!URLError(.notConnectedToInternet).isCancellation)
        #expect(!ProviderError.underlying("cancelled").isCancellation)
    }

    @Test("A manual refresh that arrives mid-fetch runs once afterwards, and its caller waits for it")
    func manualRefreshIsQueuedAndCoalesced() async throws {
        let provider = GatedProvider(holdFirst: true)
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        try await waitUntil { provider.isHolding }

        let first = Task { await coordinator.refresh(reason: "click", manual: true) }
        let second = Task { await coordinator.refresh(reason: "click again", manual: true, retryDeniedKeychainAccess: true) }
        for _ in 0..<20 { await Task.yield() }
        #expect(provider.fetchCount == 1)

        provider.release()
        await first.value
        await second.value

        // One run for both, and it had landed by the time they returned.
        #expect(provider.fetchCount == 2)
        #expect(coordinator.state.snapshot?.planName == "Fetch 2")
        coordinator.stop()
    }

    @Test("An ordinary timer refresh that arrives mid-fetch is dropped, not queued")
    func tickDuringFetchIsDropped() async throws {
        let provider = GatedProvider(holdFirst: true)
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        try await waitUntil { provider.isHolding }
        let tick = Task { await coordinator.refresh(reason: "timer") }
        await tick.value
        provider.release()
        try await waitUntil { coordinator.state.snapshot != nil }
        for _ in 0..<20 { await Task.yield() }

        #expect(provider.fetchCount == 1)
        coordinator.stop()
    }

    /// The bug: `stop()` cleared the flag while the old fetch still ran, so a
    /// restart began a second one beside it and the old fetch's defer then
    /// cleared the flag under the new one.
    @Test("Restarting while the old fetch is still running never runs two fetches at once")
    func restartDoesNotOverlap() async throws {
        let provider = GatedProvider(holdFirst: true)
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        try await waitUntil { provider.isHolding }
        coordinator.stop()
        coordinator.start()
        for _ in 0..<20 { await Task.yield() }
        #expect(provider.fetchCount == 1)

        // A tick from the new generation must not start a second either. It
        // joins the queued run, so it is released with it rather than awaited.
        let tick = Task { await coordinator.refresh(reason: "timer") }
        for _ in 0..<20 { await Task.yield() }
        #expect(provider.fetchCount == 1)

        provider.release()
        try await waitUntil { coordinator.state.snapshot != nil }
        for _ in 0..<20 { await Task.yield() }

        #expect(provider.maxConcurrent == 1)
        #expect(provider.fetchCount == 2)
        // Only the new generation's reading landed; the old one was discarded.
        #expect(coordinator.state.snapshot?.planName == "Fetch 2")
        #expect(!coordinator.isRefreshing)
        await tick.value
        coordinator.stop()
    }

    @Test("Stopping releases a caller waiting on a queued refresh instead of leaving it hanging")
    func stopReleasesQueuedCallers() async throws {
        let provider = GatedProvider(holdFirst: true)
        let coordinator = makeCoordinator(provider)

        coordinator.start()
        try await waitUntil { provider.isHolding }
        let waiting = Task { await coordinator.refresh(reason: "click", manual: true) }
        for _ in 0..<20 { await Task.yield() }

        coordinator.stop()
        await waiting.value
        provider.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(provider.fetchCount == 1)
    }

    // MARK: - Wake, and a launch inside the request floor

    @Test("A wake waits before refreshing instead of asking before the network is back")
    func wakeIsDelayed() async throws {
        let provider = GatedProvider(holdFirst: false)
        let coordinator = UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json"),
            wakeDelay: 0.4
        )
        coordinator.start()
        try await waitUntil { provider.fetchCount == 1 }
        for _ in 0..<20 { await Task.yield() }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.fetchCount == 1)

        try await waitUntil { provider.fetchCount == 2 }
        #expect(provider.fetchCount == 2)
        coordinator.stop()
    }

    @Test("Stopping before the wake delay ends cancels the wake refresh")
    func stopCancelsPendingWake() async throws {
        let provider = GatedProvider(holdFirst: false)
        let coordinator = UsageRefreshCoordinator(
            provider: provider,
            settingsStore: SettingsStore(),
            snapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json"),
            wakeDelay: 0.3
        )
        coordinator.start()
        try await waitUntil { provider.fetchCount == 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(500))

        #expect(provider.fetchCount == 1)
    }

    /// The bug: a launch inside the persisted floor either hit the endpoint or
    /// reported an error over a perfectly good snapshot on disk.
    @Test("A launch inside the request floor keeps the saved snapshot as stale data, not unavailable")
    func launchInsideFloorKeepsSnapshot() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        JSONStore.save(UsageSnapshot(
            providerID: "claude-code", planName: "Pro", windows: [],
            fetchedAt: Date().addingTimeInterval(-3600), fetchDuration: 0.1, errorMessage: nil
        ), to: url)
        let provider = GatedProvider(
            holdFirst: false, failure: ProviderError.requestFloorActive(until: Date().addingTimeInterval(120))
        )
        let coordinator = UsageRefreshCoordinator(provider: provider, settingsStore: SettingsStore(), snapshotURL: url)

        await coordinator.refresh(reason: "launch")

        guard case let .loaded(snapshot) = coordinator.state else {
            Issue.record("state became \(coordinator.state)")
            return
        }
        #expect(snapshot.planName == "Pro")
        #expect(coordinator.isStale)
        coordinator.stop()
    }

    @Test("Inside the floor with no snapshot at all, the state says so rather than counting a failure")
    func floorWithNothingToShow() async {
        let provider = GatedProvider(
            holdFirst: false, failure: ProviderError.requestFloorActive(until: Date().addingTimeInterval(120))
        )
        let coordinator = makeCoordinator(provider)

        await coordinator.refresh(reason: "launch")
        #expect(isUnavailable(coordinator.state))

        // No backoff was armed, so an immediate follow-up is not turned away.
        provider.fail(with: nil)
        await coordinator.refresh(reason: "again")
        #expect(coordinator.state.snapshot?.planName == "Fetch 2")
        coordinator.stop()
    }
}
