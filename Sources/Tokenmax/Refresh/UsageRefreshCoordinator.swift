import AppKit
import Combine
import Foundation

/// Owns the usage polling lifecycle and publishes `UsageState` to the UI.
///
/// Refresh cadence follows the spec: 60s while the popover is open, 300s in the
/// background, immediately on wake, exponential backoff after failures. The
/// network itself is separately floored at 180s inside the OAuth client, so a
/// fast UI tick costs nothing.
@MainActor
final class UsageRefreshCoordinator: ObservableObject {
    @Published private(set) var state: UsageState = .loading
    @Published private(set) var isRefreshing = false
    /// Bumped every second so countdown labels re-render without each view
    /// owning its own timer.
    @Published private(set) var tick = Date()

    /// Non-nil while the session window is in its "spend it now" stretch.
    /// The pulse animation itself lives in the menubar view — see `MenuBarLabel`.
    @Published private(set) var burnOpportunity: BurnOpportunity?

    private var previewUntil: Date?

    private let provider: any UsageProvider
    private let settingsStore: SettingsStore

    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var popoverIsOpen = false
    private var hasStarted = false
    private var consecutiveFailures = 0
    private var backoffUntil: Date?

    private static let backoffSchedule: [TimeInterval] = [30, 60, 120, 300]

    init(provider: any UsageProvider = ClaudeCodeProvider(), settingsStore: SettingsStore) {
        self.provider = provider
        self.settingsStore = settingsStore

        if let snapshot = JSONStore.load(UsageSnapshot.self, from: FileLocations.usageSnapshotFile) {
            state = .loaded(snapshot)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        observeWake()
        startTickTimer()
        scheduleRefreshTimer()
        Task { await refresh(reason: "launch") }
    }

    func popoverOpened() {
        popoverIsOpen = true
        scheduleRefreshTimer()
        Task { await refresh(reason: "popover opened") }
    }

    func popoverClosed() {
        popoverIsOpen = false
        scheduleRefreshTimer()
    }

    // MARK: - Timers

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick = Date()
                self?.updateBurnOpportunity()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Forces the opportunity on briefly so the glow can be seen and tuned
    /// without waiting for a real burn window.
    func previewBurnGlow(seconds: TimeInterval = 8) {
        previewUntil = Date().addingTimeInterval(seconds)
        updateBurnOpportunity()
        Log.shared.write("menubar: glow preview for \(Int(seconds))s")
    }

    private func updateBurnOpportunity() {
        if let previewUntil, Date() < previewUntil {
            if burnOpportunity == nil {
                burnOpportunity = BurnOpportunity(
                    kind: .session,
                    remainingPercent: state.snapshot?.sessionWindow?.remainingPercent ?? 100,
                    resetAt: previewUntil
                )
            }
            return
        }
        if previewUntil != nil {
            previewUntil = nil
            burnOpportunity = nil
        }

        let opportunity = BurnOpportunity.evaluate(
            snapshot: state.snapshot,
            settings: settingsStore.settings,
            isStale: isStale,
            now: tick
        )

        guard opportunity != burnOpportunity else { return }
        if let opportunity {
            Log.shared.write("menubar: burn opportunity active (\(Int(opportunity.remainingPercent))% left)")
        }
        burnOpportunity = opportunity
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = popoverIsOpen
            ? settingsStore.settings.foregroundRefreshSeconds
            : settingsStore.settings.backgroundRefreshSeconds

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resetBackoff()
                await self?.refresh(reason: "wake")
            }
        }
    }

    private func resetBackoff() {
        consecutiveFailures = 0
        backoffUntil = nil
    }

    // MARK: - Refresh

    /// `manual` bypasses backoff — an explicit Refresh click should always try.
    func refresh(reason: String, manual: Bool = false) async {
        if !manual, let backoffUntil, Date() < backoffUntil {
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        if manual { resetBackoff() }

        let startedAt = Date()
        do {
            let usage = try await provider.fetchUsage()
            let snapshot = UsageSnapshot(
                providerID: usage.providerID,
                planName: usage.planName,
                windows: usage.windows,
                fetchedAt: usage.fetchedAt,
                fetchDuration: Date().timeIntervalSince(startedAt),
                errorMessage: nil,
                extraUsageEnabled: usage.extraUsageEnabled
            )
            state = .loaded(snapshot)
            JSONStore.save(snapshot, to: FileLocations.usageSnapshotFile)
            resetBackoff()
            Log.shared.write("refresh(\(reason)): ok")
            NotificationCenter.default.post(name: .tokenmaxUsageUpdated, object: nil)
        } catch {
            applyFailure(error, reason: reason)
        }
    }

    private func applyFailure(_ error: Error, reason: String) {
        consecutiveFailures += 1
        let index = min(consecutiveFailures - 1, Self.backoffSchedule.count - 1)
        backoffUntil = Date().addingTimeInterval(Self.backoffSchedule[index])

        Log.shared.write("refresh(\(reason)): failed (\(consecutiveFailures)): \(error.localizedDescription)")

        // Distinct terminal states get their own UI rather than a generic error.
        if let providerError = error as? ProviderError {
            switch providerError {
            case .notInstalled:
                state = .claudeCodeNotInstalled
                return
            case .notAuthenticated:
                state = .notAuthenticated
                return
            case .accessDenied:
                state = .keychainAccessDenied
                return
            case .tokenExpired:
                // Keep showing what we last knew. This clears itself the next
                // time Claude Code runs, without the user doing anything.
                state = .tokenExpired(lastGood: state.snapshot)
                return
            case .needsReauthentication:
                state = .needsReauthentication
                return
            case .noWindowsReturned, .underlying:
                break
            }
        }

        // Otherwise keep the last good snapshot visible but clearly degraded.
        state = .unavailable(
            lastGood: state.snapshot,
            message: error.localizedDescription
        )
    }

    // MARK: - Pace

    /// How `window` is tracking against an even burn, as of this second.
    /// Recomputed per tick rather than stored, so both the pace marker and the
    /// "projected empty" countdown stay live between readings.
    func projection(for window: UsageWindow) -> UsageProjection? {
        guard settingsStore.settings.showProjections else { return nil }
        return UsageProjection.make(window: window, now: tick)
    }

    /// When a refresh would next reach the network rather than replay the OAuth
    /// client's cache. Used by the session opener to time its verification —
    /// see `SessionOpenerCoordinator.verify`.
    ///
    /// Providers other than the real one have no such floor, so they report
    /// "now": a test double should never make a caller wait.
    func nextNetworkRefreshAllowedAt() async -> Date {
        guard let provider = provider as? ClaudeCodeProvider else { return Date() }
        return await provider.nextRequestAllowedAt
    }

    // MARK: - Derived

    var isStale: Bool {
        guard let snapshot = state.snapshot else { return true }
        if case .unavailable = state { return true }
        return snapshot.isStale(now: tick, threshold: settingsStore.settings.staleAfterSeconds)
    }

    /// True while the only thing wrong is an access token Claude Code has yet to
    /// rotate. Worth distinguishing from staleness in general because it is the
    /// one failure a Claude Code run cures — which is what the session opener is.
    var isAwaitingTokenRenewal: Bool {
        if case .tokenExpired = state { return true }
        return false
    }

    var lastUpdatedText: String {
        guard let snapshot = state.snapshot else { return "Never updated" }
        let elapsed = tick.timeIntervalSince(snapshot.fetchedAt)
        return "Updated \(RelativeTime.short(elapsed)) ago"
    }
}

extension Notification.Name {
    static let tokenmaxUsageUpdated = Notification.Name("com.tokenmax.usageUpdated")
    static let tokenmaxOpenQueue = Notification.Name("com.tokenmax.openQueue")
    static let tokenmaxAppearanceChanged = Notification.Name("com.tokenmax.appearanceChanged")
}

enum RelativeTime {
    /// "3h 05m", "28m", "45s" — compact enough for the popover and menubar.
    static func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func short(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60) min" }
        if total < 86400 { return "\(total / 3600)h" }
        return "\(total / 86400)d"
    }
}
