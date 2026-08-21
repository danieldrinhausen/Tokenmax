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
    private let snapshotURL: URL

    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    /// Held so `stop()` can deregister it. Discarding the token would leave a
    /// wake observer running for a provider the user switched off.
    private var wakeObserver: NSObjectProtocol?
    /// The in-flight refresh, so `stop()` can cancel it rather than let it land
    /// on a coordinator that is no longer running.
    private var refreshTask: Task<Void, Never>?
    private var popoverIsOpen = false
    private var hasStarted = false
    private var consecutiveFailures = 0
    private var backoffUntil: Date?

    private static let backoffSchedule: [TimeInterval] = [30, 60, 120, 300]

    init(
        provider: any UsageProvider = ClaudeCodeProvider(),
        settingsStore: SettingsStore,
        snapshotURL: URL = FileLocations.usageSnapshotFile
    ) {
        self.provider = provider
        self.settingsStore = settingsStore
        self.snapshotURL = snapshotURL

        if let snapshot = JSONStore.load(UsageSnapshot.self, from: snapshotURL), snapshot.providerID == provider.identifier {
            state = .loaded(snapshot)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        observeWake()
        startTickTimer()
        scheduleRefreshTimer()
        kickOffRefresh(reason: "launch")
    }

    /// The exact mirror of `start()`, for a provider the user has switched off.
    ///
    /// Everything `start()` created that outlives the call has to be released
    /// here, or a disabled provider keeps a one-second timer, a repeating
    /// refresh, and a wake observer alive for the life of the app.
    ///
    /// `state` and the snapshot file are deliberately left alone: switching the
    /// provider back on should show its last reading immediately rather than
    /// flash "Never updated" while the first fetch runs.
    func stop() {
        guard hasStarted else { return }
        hasStarted = false

        refreshTimer?.invalidate()
        refreshTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        refreshTask?.cancel()
        refreshTask = nil

        popoverIsOpen = false
        previewUntil = nil
        burnOpportunity = nil
        isRefreshing = false
        resetBackoff()

        Log.shared.write("usage: stopped polling \(provider.identifier)")
    }

    /// `hasStarted` guards both popover paths because they call
    /// `scheduleRefreshTimer()` unconditionally — without the guard, opening the
    /// popover would rebuild the timer of a provider that has been switched off.
    func popoverOpened() {
        popoverIsOpen = true
        guard hasStarted else { return }
        scheduleRefreshTimer()
        kickOffRefresh(reason: "popover opened")
    }

    func popoverClosed() {
        popoverIsOpen = false
        guard hasStarted else { return }
        scheduleRefreshTimer()
    }

    /// Refreshes through a retained handle so `stop()` has something to cancel.
    private func kickOffRefresh(reason: String, manual: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.refresh(reason: reason, manual: manual)
        }
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
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

        if manual {
            resetBackoff()
            // A remembered keychain denial is cleared here and nowhere else:
            // the denied state in the popover says "click Refresh", and that
            // click — not a timer tick — is the "ask me again" it waits for.
            (provider as? ClaudeCodeProvider)?.retryDeniedKeychainAccess()
        }

        let startedAt = Date()
        do {
            let usage = try await provider.fetchUsage()
            // The provider may have been switched off while this was in flight.
            // A stopped coordinator must not be repopulated behind the user's back.
            guard !Task.isCancelled else { return }
            let snapshot = UsageSnapshot(
                providerID: usage.providerID,
                planName: usage.planName,
                windows: usage.windows,
                fetchedAt: usage.fetchedAt,
                fetchDuration: Date().timeIntervalSince(startedAt),
                errorMessage: nil,
                extraUsageEnabled: usage.extraUsageEnabled
            )

            // `ClaudeOAuthUsageClient` correctly replays its response while
            // inside its request floor. That replay is not evidence that
            // anything changed, so it must not clear a pending token renewal:
            // no token was renewed, and the session opener needs that fact to
            // make its one safe recovery attempt. A newer observation
            // (including a statusline update) is what clears it.
            let isNewObservation = lastObservedAt.map { snapshot.fetchedAt > $0 } ?? true
            if isNewObservation { lastObservedAt = snapshot.fetchedAt }

            if isAwaitingTokenRenewal, !isNewObservation {
                state = .tokenExpired(lastGood: snapshot)
                Log.shared.write("refresh(\(reason)): cached while awaiting Claude token renewal")
                NotificationCenter.default.post(name: .tokenmaxUsageUpdated, object: nil)
                return
            }

            isAwaitingTokenRenewal = false
            // A reading arrived, so whatever the login was, it meters quota now.
            isAPIKeyOnly = false
            state = .loaded(snapshot)
            JSONStore.save(snapshot, to: snapshotURL)
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
                isAwaitingTokenRenewal = true
                state = .tokenExpired(lastGood: state.snapshot)
                return
            case .needsReauthentication:
                // A run of Claude Code cannot fix this one — the refresh token
                // is gone and only a sign-in will do. The opener must not think
                // it has a recovery available.
                isAwaitingTokenRenewal = false
                state = .needsReauthentication
                return
            case .apiKeyConfigured:
                // Not a terminal state of its own: the message below says what
                // happened, and any last good reading stays on screen. The flag
                // is what the queue reads, so it can refuse a run with the real
                // reason rather than reporting a missing quota window.
                isAPIKeyOnly = true
            // `.statuslineNoData` lands here on purpose: "no reading yet" in
            // statusline-only mode keeps any last good reading on screen with
            // the message underneath, exactly like a transient failure. It is
            // not an auth state — there is nothing the user must grant.
            case .noWindowsReturned, .statuslineNoData, .underlying:
                break
            }
        }

        // A transient failure on top of a pending token renewal does not
        // replace the diagnosis. Relabelling it — a rate-limit reading as
        // "Usage unavailable" — hid the real blocker from the user and, worse,
        // cleared the opener's recovery path along with the state.
        if isAwaitingTokenRenewal {
            state = .tokenExpired(lastGood: state.snapshot)
            return
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
    ///
    /// Deliberately a stored fact rather than a reading of `state`. Derived from
    /// the state it was silently wrong: any refresh that returned without
    /// throwing — a cached replay inside the 180s floor, a rate-limit landing as
    /// `.unavailable` — overwrote `.tokenExpired` and took the opener's one
    /// recovery path with it. The opener would then refuse, on stale data, to
    /// perform the only action that clears the staleness. Only a genuinely newer
    /// observation clears this now.
    @Published private(set) var isAwaitingTokenRenewal = false

    /// Whether the last refresh found an API-key login rather than a
    /// subscription one.
    ///
    /// A stored fact for the same reason as the flag above: the state it
    /// produces is an ordinary `.unavailable`, indistinguishable from a network
    /// blip, and the queue must not refuse a run on a blip nor allow one on a
    /// login that would be billed per token. Cleared by any successful reading.
    @Published private(set) var isAPIKeyOnly = false

    /// The newest observation actually seen, used to tell a fresh reading from
    /// the client replaying the one we already had.
    private var lastObservedAt: Date?

    var lastUpdatedText: String {
        guard let snapshot = state.snapshot else { return "Never updated" }
        let elapsed = tick.timeIntervalSince(snapshot.fetchedAt)
        return "Updated \(RelativeTime.short(elapsed)) ago"
    }
}

extension Notification.Name {
    static let tokenmaxUsageUpdated = Notification.Name("com.tokenmax.usageUpdated")
    static let tokenmaxOpenQueue = Notification.Name("com.tokenmax.openQueue")
    static let tokenmaxOpenSettings = Notification.Name("com.tokenmax.openSettings")
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
