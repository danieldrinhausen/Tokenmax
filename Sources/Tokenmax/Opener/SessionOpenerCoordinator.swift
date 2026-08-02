import Combine
import Foundation

/// Applies `SessionOpener.decide` to live data, runs the opener, and verifies
/// that a new window actually appeared.
///
/// Mirrors `NotificationCoordinator`: the decision itself is pure and lives
/// elsewhere; this owns the timing, the process, the persistence, and the
/// published status the UI reads.
@MainActor
final class SessionOpenerCoordinator: ObservableObject {
    /// The most recent decision, so Settings and the popover can explain a
    /// silence instead of looking broken.
    @Published private(set) var decision: SessionOpenerDecision = .skip(reason: .disabled)
    @Published private(set) var isRunning = false
    @Published private(set) var lastAttempt: SessionOpenerAttempt?

    private let usage: UsageRefreshCoordinator
    private let settingsStore: SettingsStore

    private var state: SessionOpenerState
    private var cancellables: Set<AnyCancellable> = []

    /// `claude auth status` spawns a process, so it is not something to do on a
    /// one-second tick. Re-read at most this often.
    private static let authCacheLifetime: TimeInterval = 300
    private var cachedAuth: (status: ClaudeAuthStatus?, readAt: Date)?

    /// `ClaudeCLIClient.locate()` falls back to asking a login shell, so it can
    /// spawn a process. Evaluated on a one-second tick, that would be a
    /// subprocess per second for anyone whose `claude` is not on a standard
    /// path. The answer changes about as often as an install does.
    private static let cliCacheLifetime: TimeInterval = 300
    private var cachedCLIInstalled: (value: Bool, readAt: Date)?

    /// Both gates cached together: `authStatus` spawns a process and the
    /// settings check reads a file, neither worth doing every second while a
    /// gate is holding the opener back.
    private static let gateCacheLifetime: TimeInterval = 60
    private var cachedGate: (reason: SessionOpenerDecision.SkipReason?, readAt: Date)?
    private var hasStarted = false

    /// How many times a single run is allowed to look for its new window, and
    /// how far apart. Three attempts straddle the OAuth client's 180s floor
    /// comfortably.
    private static let maxVerifyAttempts = 3

    init(usage: UsageRefreshCoordinator, settingsStore: SettingsStore) {
        self.usage = usage
        self.settingsStore = settingsStore
        state = JSONStore.load(SessionOpenerState.self, from: FileLocations.sessionOpenerStateFile)
            ?? SessionOpenerState()
        lastAttempt = state.mostRecentAttempt
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Every successful refresh is both a chance to learn the current reset
        // time and a chance to act on it.
        NotificationCenter.default.addObserver(
            forName: .tokenmaxUsageUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }

        // The refresh cadence is 300s in the background — far too coarse for a
        // 60s delay after reset — so the decision is re-evaluated on the same
        // one-second tick that drives the countdown. Every guard is a
        // comparison; nothing spawns or connects until they all pass.
        usage.$tick
            .sink { [weak self] _ in
                Task { @MainActor in await self?.evaluate() }
            }
            .store(in: &cancellables)

        // A settings change should take effect at once rather than at the next
        // tick boundary — and toggling the feature on mid-cycle is exactly when
        // the user is watching for a response.
        settingsStore.$settings
            .map(\.sessionOpener)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.evaluate() }
            }
            .store(in: &cancellables)

        Task { await evaluate() }
    }

    // MARK: - Evaluation

    private func makeInput(now: Date = Date()) -> SessionOpener.Input {
        let snapshot = usage.state.snapshot
        return SessionOpener.Input(
            settings: settingsStore.settings.sessionOpener,
            quietHours: settingsStore.settings.quietHours,
            sessionWindow: snapshot?.sessionWindow,
            weeklyWindow: snapshot?.weeklyWindow,
            extraUsageEnabled: snapshot?.extraUsageEnabled,
            isStale: usage.isStale,
            cliInstalled: cliInstalled(),
            state: state,
            now: now
        )
    }

    private func cliInstalled() -> Bool {
        if let cachedCLIInstalled, Date().timeIntervalSince(cachedCLIInstalled.readAt) < Self.cliCacheLifetime {
            return cachedCLIInstalled.value
        }
        let value = ClaudeCLIClient.isInstalled
        cachedCLIInstalled = (value, Date())
        return value
    }

    /// Records the current session reset time so the opener still knows a window
    /// ended even if nothing was running when it did.
    private func learnResetTime() {
        guard let resetAt = usage.state.snapshot?.sessionWindow?.resetAt else { return }
        guard state.lastKnownSessionResetAt != resetAt else { return }
        state.lastKnownSessionResetAt = resetAt
        persist()
    }

    private func evaluate() async {
        guard !isRunning else { return }

        learnResetTime()

        // The common case by far — the feature is off by default. Bail before
        // touching anything that costs more than a bool.
        guard settingsStore.settings.sessionOpener.enabled else {
            publish(.skip(reason: .disabled))
            return
        }

        let input = makeInput()
        var outcome = SessionOpener.decide(input)

        // Staleness postpones rather than cancels — there is no deadline here,
        // unlike a reminder. Spend one backoff-bypassing refresh per cycle
        // trying to unstick it, then leave the ordinary cadence to it rather
        // than hammering past the backoff that exists to prevent exactly that.
        if outcome.skipReason == .dataStale, settingsStore.settings.sessionOpener.enabled {
            await forceRefreshOnceIfStale()
        }

        if case .open = outcome, let gate = expensiveGate() {
            outcome = .skip(reason: gate)
        }

        publish(outcome)

        guard case let .open(cycleID) = outcome else { return }
        await open(cycleID: cycleID, reason: "automatic")
    }

    private func publish(_ outcome: SessionOpenerDecision) {
        guard decision != outcome else { return }
        decision = outcome
        if let reason = outcome.skipReason {
            // Routine waiting states would drown the log; the rest are the ones
            // worth being able to explain after the fact.
            if reason.isNoteworthy || reason == .dataStale {
                Log.shared.write("opener: \(reason.rawValue)")
            }
        } else if let cycleID = outcome.cycleID {
            Log.shared.write("opener: eligible for \(cycleID)")
        }
    }

    private func forceRefreshOnceIfStale() async {
        guard let expiredResetAt = state.lastKnownSessionResetAt else { return }
        let cycleID = SessionOpener.cycleID(expiredResetAt: expiredResetAt)
        guard !state.hasForcedRefresh(cycleID) else { return }

        state.markForcedRefresh(cycleID)
        persist()
        Log.shared.write("opener: forcing refresh (stale) for \(cycleID)")
        await usage.refresh(reason: "opener", manual: true)
    }

    /// The two checks that need a subprocess or a file read. Run only once the
    /// cheap guards have all passed, so a disabled feature never spawns anything.
    ///
    /// `force` is for the manual controls, where the user has just changed
    /// something and expects the answer to reflect it.
    private func expensiveGate(force: Bool = false) -> SessionOpenerDecision.SkipReason? {
        if !force, let cachedGate, Date().timeIntervalSince(cachedGate.readAt) < Self.gateCacheLifetime {
            return cachedGate.reason
        }
        if force { cachedAuth = nil }

        var reason = SessionOpener.authGate(authStatus())
        if reason == nil {
            let data = try? Data(contentsOf: FileLocations.claudeSettingsFile)
            reason = SessionOpener.settingsGate(data)
        }
        cachedGate = (reason, Date())
        return reason
    }

    private func authStatus() -> ClaudeAuthStatus? {
        if let cachedAuth, Date().timeIntervalSince(cachedAuth.readAt) < Self.authCacheLifetime {
            return cachedAuth.status
        }
        let status = ClaudeCLIClient.authStatus()
        cachedAuth = (status, Date())
        return status
    }

    // MARK: - Running

    private func open(cycleID: String, reason: String) async {
        isRunning = true
        defer { isRunning = false }

        let model = settingsStore.settings.sessionOpener.model
        let startedAt = Date()

        // Written *before* the process starts. A crash between spawning and
        // recording would otherwise leave no trace of a request that was really
        // sent, and the next launch would send another.
        var attempt = SessionOpenerAttempt(
            cycleID: cycleID,
            startedAt: startedAt,
            outcome: .failed,
            model: model,
            errorMessage: "Interrupted before the CLI answered."
        )
        state.record(attempt)
        persist()
        lastAttempt = attempt

        Log.shared.write("opener: sending (\(reason), model=\(model), cycle=\(cycleID))")

        let result = await Task.detached(priority: .userInitiated) {
            ClaudeOpenerRunner.run(model: model)
        }.value

        attempt.outcome = result.succeeded ? .sent : .failed
        attempt.resultText = result.text
        attempt.errorMessage = result.errorMessage
        attempt.costUSD = result.costUSD
        attempt.sessionID = result.sessionID
        state.record(attempt)
        persist()
        lastAttempt = attempt

        guard result.succeeded else {
            Log.shared.write("opener: failed — \(result.errorMessage ?? "unknown")")
            return
        }

        Log.shared.write("opener: sent, CLI replied \(result.text.map { "\"\($0)\"" } ?? "(empty)")")

        guard settingsStore.settings.sessionOpener.verifyAfterRun else {
            attempt.outcome = .verified
            state.record(attempt)
            persist()
            lastAttempt = attempt
            return
        }

        await verify(attempt)
    }

    /// Confirms the reset timestamp actually advanced.
    ///
    /// The wait is not arbitrary: `ClaudeOAuthUsageClient` floors network calls
    /// at 180s and replays its cache in between, so a refresh issued straight
    /// after the run would re-read the *pre-opener* response and conclude the
    /// window never opened. Waiting for the floor to lift is the difference
    /// between verifying the run and failing it for no reason.
    private func verify(_ attempt: SessionOpenerAttempt) async {
        var attempt = attempt

        for _ in 0 ..< Self.maxVerifyAttempts {
            let allowedAt = await usage.nextNetworkRefreshAllowedAt()
            let waitUntil = max(Date().addingTimeInterval(20), allowedAt.addingTimeInterval(5))
            let seconds = waitUntil.timeIntervalSinceNow
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }

            await usage.refresh(reason: "opener verify", manual: true)

            attempt.verifyAttempts += 1

            if SessionOpener.didWindowOpen(
                sessionWindow: usage.state.snapshot?.sessionWindow,
                sentAt: attempt.startedAt
            ) {
                attempt.outcome = .verified
                attempt.verifiedResetAt = usage.state.snapshot?.sessionWindow?.resetAt
                state.record(attempt)
                persist()
                lastAttempt = attempt
                Log.shared.write(
                    "opener: verified — new window resets \(attempt.verifiedResetAt.map(String.init(describing:)) ?? "?")"
                )
                return
            }

            state.record(attempt)
            persist()
            lastAttempt = attempt
        }

        // Terminal by design. Retrying an unverifiable opener spends real quota
        // chasing a state we cannot confirm, which is the one thing this feature
        // must never do.
        attempt.outcome = .unverified
        state.record(attempt)
        persist()
        lastAttempt = attempt
        Log.shared.write("opener: could not verify a new window; no further attempts this cycle")
    }

    // MARK: - Manual controls

    /// Evaluates every guard, including the two expensive ones, and returns the
    /// verdict without spending anything.
    func checkEligibility() -> SessionOpenerDecision {
        learnResetTime()
        // The button exists to give a current answer, so nothing is served from
        // cache: the user may have just edited ~/.claude/settings.json.
        cachedCLIInstalled = nil
        var outcome = SessionOpener.decide(makeInput())
        if case .open = outcome, let gate = expensiveGate(force: true) {
            outcome = .skip(reason: gate)
        }
        publish(outcome)
        return outcome
    }

    /// Backs the "Send opener now" button. Still refuses when a gate fails —
    /// the button bypasses the *schedule*, never the safety conditions.
    @discardableResult
    func sendNow() async -> SessionOpenerDecision {
        let outcome = checkEligibility()
        guard case let .open(cycleID) = outcome else { return outcome }
        await open(cycleID: cycleID, reason: "manual")
        return outcome
    }

    private func persist() {
        JSONStore.save(state, to: FileLocations.sessionOpenerStateFile)
    }
}
