import AppKit
import Combine
import Foundation

/// A run that has been decided on but not yet started.
///
/// The countdown exists so full automation is not a surprise: even in
/// `.automatic` mode there is a window in which an unintended run can be
/// stopped, without turning every run into a confirmation dialog.
struct PendingAutoRun: Equatable, Sendable {
    var taskID: UUID
    var taskTitle: String
    var providerID: String
    var windowID: String
    var startsAt: Date

    func secondsRemaining(now: Date) -> Int {
        max(0, Int(startsAt.timeIntervalSince(now).rounded(.up)))
    }
}

/// Applies `QueueAutoRun.decide` to live data, runs the task, and records what
/// happened.
///
/// Mirrors `SessionOpenerCoordinator`: the decision is pure and lives elsewhere;
/// this owns the timing, the process, the persistence, and the published state
/// the UI reads.
@MainActor
final class QueueAutoRunCoordinator: ObservableObject {
    /// The most recent decision, so the UI can explain a silence instead of
    /// looking broken.
    @Published private(set) var decision: QueueAutoRunDecision = .skip(reason: .disabled)
    @Published private(set) var activeRun: TaskRunRecord?
    @Published private(set) var pendingRun: PendingAutoRun?
    @Published private(set) var progressText: String?
    @Published private(set) var lastRun: TaskRunRecord?
    /// True between a run finishing and a usage reading newer than it arriving.
    @Published private(set) var awaitingFreshUsage = false

    private let usage: ProviderUsageCoordinator
    private let taskStore: TaskStore
    private let settingsStore: SettingsStore
    private let notifications: AutoRunNotifier

    private var state: QueueAutoRunState
    private var cancellables: Set<AnyCancellable> = []
    private var runTask: Task<Void, Never>?
    /// Set when a run finishes; cleared once a snapshot fetched after it lands.
    private var freshUsageNeededAfter: Date?
    private var hasStarted = false

    /// Same reasoning as `SessionOpenerCoordinator`: locating the CLI can spawn
    /// a login shell, which is not something to do on a one-second tick.
    private static let cliCacheLifetime: TimeInterval = 300
    private var cachedCLIInstalled: (value: Bool, readAt: Date)?

    private static let gateCacheLifetime: TimeInterval = 60
    private var cachedGate: (reason: SessionOpenerDecision.SkipReason?, readAt: Date)?
    private var cachedAuth: (status: ClaudeAuthStatus?, readAt: Date)?

    /// How long to wait for a post-run reading before giving up and reporting
    /// the queue as paused rather than guessing from stale numbers.
    private static let freshUsageTimeout: TimeInterval = 600

    init(
        usage: ProviderUsageCoordinator,
        taskStore: TaskStore,
        settingsStore: SettingsStore,
        notifications: AutoRunNotifier = AutoRunNotifier()
    ) {
        self.usage = usage
        self.taskStore = taskStore
        self.settingsStore = settingsStore
        self.notifications = notifications
        state = JSONStore.load(QueueAutoRunState.self, from: FileLocations.queueAutoRunStateFile)
            ?? QueueAutoRunState()
        lastRun = state.mostRecentRun
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        recoverInterruptedRuns()

        NotificationCenter.default.addObserver(
            forName: .tokenmaxUsageUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteUsageArrived()
                self?.evaluate()
            }
        }

        // The countdown needs a second-resolution clock, and the refresh cadence
        // is 300s in the background — far too coarse. Every guard is a
        // comparison; nothing spawns until they all pass.
        usage.$tick
            .sink { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.queueAutoRun)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] settings in
                Task { @MainActor in
                    self?.notifications.apply(settings)
                    // Changing the settings mid-countdown should not let a run
                    // the user just reconfigured slip through on the old terms.
                    self?.cancelPending(reason: "settings changed")
                    self?.evaluate()
                }
            }
            .store(in: &cancellables)

        notifications.apply(settingsStore.settings.queueAutoRun)
        observeNotificationActions()
        evaluate()
    }

    // MARK: - Recovery

    /// Reconciles runs that were in flight when Tokenmax last stopped.
    ///
    /// Keyed on run records rather than on task status, unlike the obvious
    /// approach of sweeping every `.running` task at launch. That would break
    /// the manual terminal path, where a task legitimately stays `.running`
    /// across a restart while the user works in the terminal it opened. Only
    /// tasks Tokenmax itself started have a record, and only those are touched.
    private func recoverInterruptedRuns() {
        let unfinished = state.unfinishedRuns
        guard !unfinished.isEmpty else { return }

        for var run in unfinished {
            run.status = .interrupted
            run.finishedAt = Date()
            run.errorMessage = "Tokenmax was interrupted while this task was running."
            state.record(run)

            if let task = taskStore.tasks.first(where: { $0.id == run.taskID }), task.status == .running {
                taskStore.markNeedsAttention(task, message: run.errorMessage ?? "Interrupted.")
            }
            Log.shared.write("autorun: recovered interrupted run \(run.id) (\(run.taskTitle))")
        }

        persist()
        lastRun = state.mostRecentRun
    }

    // MARK: - Evaluation

    private func makeInput(provider requestedProvider: TokenmaxProvider? = nil, now: Date = Date()) -> QueueAutoRun.Input {
        let provider = requestedProvider ?? usage.selectedProvider
        let snapshot = usage.snapshot(for: provider)
        var settings = settingsStore.settings.queueAutoRun
        // A provider the user switched off has stopped refreshing, so its
        // snapshot is frozen — and every quota gate below reads that snapshot.
        // Nothing may run against it.
        if !settingsStore.settings.isEnabled(provider) { settings.enabled = false }
        if provider == .codex && !settingsStore.settings.codexAutoRunEnabled { settings.enabled = false }
        return QueueAutoRun.Input(
            providerID: provider.rawValue,
            settings: settings,
            queueEnabled: settingsStore.settings.queueEnabled,
            quietHours: settingsStore.settings.quietHours,
            sessionWindow: snapshot?.sessionWindow,
            weeklyWindow: snapshot?.weeklyWindow,
            isStale: usage.isStale(for: provider),
            cliInstalled: cliInstalled(provider),
            tasks: taskStore.readyTasks.filter { $0.provider == provider },
            state: state,
            runInFlight: activeRun != nil,
            awaitingFreshUsage: awaitingFreshUsage,
            now: now
        )
    }

    /// The providers the user is still monitoring. Never empty.
    private var enabledProviders: [TokenmaxProvider] { settingsStore.settings.enabledProviders }

    private func cliInstalled(_ provider: TokenmaxProvider = .claudeCode) -> Bool {
        if provider == .codex { return CodexCLIClient.isInstalled }
        if let cachedCLIInstalled, Date().timeIntervalSince(cachedCLIInstalled.readAt) < Self.cliCacheLifetime {
            return cachedCLIInstalled.value
        }
        let value = ClaudeCLIClient.isInstalled
        cachedCLIInstalled = (value, Date())
        return value
    }

    private func evaluate() {
        if activeRun != nil {
            enforceResetBoundary()
            return
        }

        // The common case by far — the feature is off by default. Bail before
        // touching anything that costs more than a bool.
        guard settingsStore.settings.queueAutoRun.enabled else {
            publish(.skip(reason: .disabled))
            pendingRun = nil
            return
        }

        // A countdown already running just needs the clock checked.
        if let pending = pendingRun {
            if Date() >= pending.startsAt {
                pendingRun = nil
                beginRun(taskID: pending.taskID, windowID: pending.windowID, trigger: .automatic)
            }
            return
        }

        // A disabled provider is not merely skipped, it is never consulted: its
        // snapshot has stopped refreshing and would be judged as though current.
        let outcomes = enabledProviders.map { provider in
            (provider, QueueAutoRun.decide(makeInput(provider: provider)))
        }
        // Three tiers: the first eligible verdict, else the verdict for the
        // provider whose meter is on screen (so the UI explains what the user is
        // looking at), else any verdict at all. The last tier is what makes this
        // total — `selectedProvider` is derived from the same settings and can
        // momentarily disagree with this list mid-change.
        guard var outcome = outcomes.first(where: { $0.1.isEligible })?.1
            ?? outcomes.first(where: { $0.0 == usage.selectedProvider })?.1
            ?? outcomes.first?.1
        else {
            publish(.skip(reason: .disabled))
            pendingRun = nil
            return
        }

        // The account gates cost a subprocess and a file read, so they only run
        // once the cheap guards have all passed.
        if outcome.isEligible,
           let taskID = outcome.taskID,
           taskStore.tasks.first(where: { $0.id == taskID })?.provider == .claudeCode,
           let gate = QueueAutoRun.accountGate(expensiveGate()) {
            outcome = .skip(reason: gate)
        }

        publish(outcome)

        switch outcome {
        case let .run(taskID, windowID):
            schedulePendingRun(taskID: taskID, windowID: windowID)
        case let .ask(taskID, windowID):
            notifyEligible(taskID: taskID, windowID: windowID)
        case .preview, .skip:
            break
        }
    }

    /// Stops a running task at the safety deadline, but only if the user asked
    /// for that.
    ///
    /// The default is to let it finish. A reset is not a reason to kill work in
    /// progress: the quota it was going to spend has already been spent, and a
    /// task terminated halfway through an edit leaves the project worse than
    /// never having run it. Only a deliberate opt-in changes that.
    private func enforceResetBoundary() {
        guard settingsStore.settings.queueAutoRun.resetBoundaryBehavior == .stopAtDeadline else { return }
        guard let resetAt = usage.snapshot(for: activeRun.flatMap { TokenmaxProvider.from(identifier: $0.providerID) } ?? usage.selectedProvider)?.sessionWindow?.resetAt else { return }

        let deadline = QueueAutoRun.effectiveDeadline(
            resetAt: resetAt,
            settings: settingsStore.settings.queueAutoRun
        )
        guard Date() >= deadline else { return }

        Log.shared.write("autorun: stopping at the safety deadline (stopAtDeadline is on)")
        stop()
    }

    private func publish(_ outcome: QueueAutoRunDecision) {
        guard decision != outcome else { return }
        decision = outcome
        if let reason = outcome.skipReason {
            // Routine waiting states would drown the log.
            if reason.isNoteworthy { Log.shared.write("autorun: \(reason.rawValue)") }
        } else if let taskID = outcome.taskID {
            let title = taskStore.tasks.first { $0.id == taskID }?.title ?? "?"
            Log.shared.write("autorun: eligible — \(title)")
        }
    }

    /// The two checks that need a subprocess or a file read, reused wholesale
    /// from the session opener: a queued task must never run against
    /// pay-as-you-go API billing either.
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
        if let cachedAuth, Date().timeIntervalSince(cachedAuth.readAt) < 300 {
            return cachedAuth.status
        }
        let status = ClaudeCLIClient.authStatus()
        cachedAuth = (status, Date())
        return status
    }

    // MARK: - Countdown

    private func schedulePendingRun(taskID: UUID, windowID: String) {
        guard pendingRun == nil else { return }
        guard let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }

        let delay = Double(settingsStore.settings.queueAutoRun.startDelaySeconds)
        pendingRun = PendingAutoRun(
            taskID: taskID,
            taskTitle: task.title,
            providerID: task.providerID,
            windowID: windowID,
            startsAt: Date().addingTimeInterval(delay)
        )
        Log.shared.write("autorun: starting \(task.title) in \(Int(delay))s")
        notifications.eligible(task: task, startingInSeconds: Int(delay), autoStart: true)
    }

    private func notifyEligible(taskID: UUID, windowID _: String) {
        guard let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }
        notifications.eligible(task: task, startingInSeconds: nil, autoStart: false)
    }

    /// Cancelling during the countdown costs nothing — no process has started.
    func cancelPending(reason: String = "user") {
        guard let pending = pendingRun else { return }
        pendingRun = nil
        Log.shared.write("autorun: countdown cancelled (\(reason)) for \(pending.taskTitle)")
    }

    /// Starts a pending run immediately, skipping the rest of the countdown.
    func startPendingNow() {
        guard let pending = pendingRun else { return }
        pendingRun = nil
        beginRun(taskID: pending.taskID, windowID: pending.windowID, trigger: .automatic)
    }

    // MARK: - Running

    private func beginRun(taskID: UUID, windowID: String, trigger: RunTrigger) {
        guard activeRun == nil else { return }
        guard let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }
        run(task, windowID: windowID, trigger: trigger)
    }

    /// `reply` continues `resuming`'s conversation instead of starting the task
    /// from its own prompt. Everything else about the run is identical, which is
    /// the point: a follow-up gets the same caps, gates, and recording.
    private func run(
        _ task: TokenmaxTask,
        windowID: String,
        trigger: RunTrigger,
        reply: String? = nil,
        resuming sessionID: String? = nil
    ) {
        let runID = UUID()
        var record = TaskRunRecord(
            id: runID,
            taskID: task.id,
            taskTitle: task.title,
            windowID: windowID,
            trigger: trigger,
            providerID: task.providerID,
            model: task.selectedModel,
            effort: task.selectedEffort,
            workingDirectory: task.workingDirectory ?? "",
            status: .starting,
            sessionRemainingBefore: usage.snapshot(for: task.provider)?.sessionWindow?.remainingPercent
        )
        record.outputFile = FileLocations.runLogFile(runID: runID).lastPathComponent
        record.replyText = reply
        // Set now rather than on completion so the turn joins its thread even if
        // it is interrupted — otherwise a crashed reply orphans itself.
        record.sessionID = sessionID

        // Written *before* the process starts, for the same reason the opener
        // does it: a crash between spawning and recording would leave no trace
        // of quota that was really spent, and the next launch would run again.
        state.record(record)
        persist()

        activeRun = record
        lastRun = record
        progressText = "Starting…"
        taskStore.setStatus(.running, for: task)
        notifications.started(task: task)

        Log.shared.write("autorun: run \(runID) started (\(trigger.rawValue)) — \(task.title)")

        runTask = Task { [weak self] in
            let progress: @Sendable (String) -> Void = { text in
                Task { @MainActor in self?.progressText = text }
            }
            let result: ClaudeTaskRunner.Result
            if task.provider == .codex {
                result = await CodexTaskRunner.run(
                    task: task, runID: runID, prompt: reply, resuming: sessionID, onProgress: progress
                )
            } else {
                result = await ClaudeTaskRunner.run(
                    task: task, runID: runID, prompt: reply, resuming: sessionID, onProgress: progress
                )
            }
            await self?.finish(record: record, task: task, result: result)
        }
    }

    private func finish(record: TaskRunRecord, task: TokenmaxTask, result: ClaudeTaskRunner.Result) async {
        var record = record
        record.status = result.status
        record.finishedAt = Date()
        record.exitCode = result.exitCode
        record.errorMessage = result.errorMessage
        record.resultText = result.resultText
        record.costUSD = result.costUSD
        // Never overwrite a resumed thread's ID with nil: a reply that failed
        // before the CLI reported an envelope still belongs to its conversation,
        // and losing the ID here would strand every earlier turn.
        record.sessionID = result.sessionID ?? record.sessionID
        // Session persistence is on for task runs, so an ID means a transcript
        // the user can still continue from.
        record.isResumable = record.sessionID != nil
        state.record(record)

        if result.status.pausesQueue, settingsStore.settings.queueAutoRun.pauseAfterFailure {
            state.pause(record.windowID)
            Log.shared.write("autorun: queue paused for \(record.windowID) after \(result.status.rawValue)")
        }
        persist()

        activeRun = nil
        lastRun = record
        progressText = nil
        runTask = nil

        switch result.status {
        case .completed:
            taskStore.setStatus(.completed, for: task)
            notifications.completed(record: record)
        case .cancelled:
            // Back to ready rather than needing attention: the user stopped it
            // on purpose, and the obvious next thing is to run it again.
            taskStore.setStatus(.ready, for: task)
        case .budgetExceeded:
            taskStore.markNeedsAttention(task, message: result.errorMessage ?? "Reached its budget limit.")
            notifications.completed(record: record)
        default:
            taskStore.markNeedsAttention(task, message: result.errorMessage ?? "The task did not finish.")
            notifications.failed(record: record)
        }

        Log.shared.write(
            "autorun: run \(record.id) \(result.status.rawValue)"
                + (result.costUSD.map { String(format: " ($%.4f)", $0) } ?? "")
        )

        // Never re-evaluate off the pre-run snapshot: the numbers that decide
        // whether another task may start are exactly the ones this run changed.
        freshUsageNeededAfter = record.finishedAt
        awaitingFreshUsage = true
        await requestPostRunRefresh()
    }

    /// Asks for a reading that reflects the run just finished.
    ///
    /// `ClaudeOAuthUsageClient` floors network calls at 180s and replays its
    /// cache in between, so a refresh issued straight away would re-read the
    /// *pre-run* response. Waiting for the floor to lift is the difference
    /// between a real reading and a stale one presented as fresh — the same
    /// reasoning as `SessionOpenerCoordinator.verify`.
    private func requestPostRunRefresh() async {
        let provider = TokenmaxProvider.from(identifier: lastRun?.providerID ?? "") ?? .claudeCode
        let allowedAt = await usage.nextNetworkRefreshAllowedAt(for: provider)
        let seconds = max(0, allowedAt.timeIntervalSinceNow + 5)
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        await usage.refresh(reason: "autorun post-run", manual: true, provider: provider)
    }

    /// Clears the post-run wait once a reading newer than the run arrives.
    private func noteUsageArrived() {
        guard let needed = freshUsageNeededAfter else { return }
        let provider = TokenmaxProvider.from(identifier: lastRun?.providerID ?? "") ?? .claudeCode
        guard let snapshot = usage.snapshot(for: provider) else { return }

        if snapshot.fetchedAt > needed {
            freshUsageNeededAfter = nil
            awaitingFreshUsage = false
            if var run = lastRun, run.sessionRemainingAfter == nil, run.status.isFinished {
                run.sessionRemainingAfter = snapshot.sessionWindow?.remainingPercent
                state.record(run)
                persist()
                lastRun = run
            }
            Log.shared.write("autorun: fresh reading after run")
        } else if Date().timeIntervalSince(needed) > Self.freshUsageTimeout {
            // Give up waiting rather than blocking forever, but stay in the
            // "awaiting" state so no further task starts on numbers we do not
            // trust. The user sees why in the popover.
            Log.shared.write("autorun: still no fresh reading \(Int(Self.freshUsageTimeout))s after the run")
        }
    }

    // MARK: - Manual controls

    /// Evaluates every guard, including the expensive ones, and returns the
    /// verdict without spending anything.
    @discardableResult
    func checkEligibility() -> QueueAutoRunDecision {
        cachedCLIInstalled = nil
        let provider = usage.selectedProvider
        var outcome = QueueAutoRun.decide(makeInput(provider: provider))
        // Nothing served from cache: the button exists to give a current
        // answer, and the user may have just edited ~/.claude/settings.json.
        if provider == .claudeCode,
           outcome.isEligible,
           let gate = QueueAutoRun.accountGate(expensiveGate(force: true)) {
            outcome = .skip(reason: gate)
        }
        publish(outcome)
        return outcome
    }

    /// Backs "Run next eligible task now".
    ///
    /// Bypasses the schedule — lead window, countdown, per-window caps, quota
    /// thresholds — because the point is to test the runner without waiting for
    /// a burn window. It does not bypass the conditions that make a run unsafe
    /// or impossible; those are re-checked in `runManually`.
    @discardableResult
    func runNextEligibleNow() -> QueueAutoRunDecision.SkipReason? {
        let enabled = enabledProviders
        guard !enabled.isEmpty else { return .disabled }
        // Both halves drawn from the enabled set rather than prepending
        // `selectedProvider` outright, which would consult a disabled provider
        // whenever the two disagree.
        let providers = enabled.filter { $0 == usage.selectedProvider }
            + enabled.filter { $0 != usage.selectedProvider }
        for provider in providers {
            let input = makeInput(provider: provider)
            let candidates = QueueAutoRun.approvedTasks(input)
            if let task = candidates.first(where: { $0.workingDirectoryExists }) {
                return runManually(task)
            }
            if !candidates.isEmpty { return .workingDirectoryMissing }
        }
        return .noApprovedTask
    }

    /// Backs the per-card "Run with Claude".
    ///
    /// The execution-mode gate does not apply here: clicking the button *is*
    /// the approval, and requiring a task to be marked `.automatic` before it
    /// could be run by hand would make the safe default untestable.
    @discardableResult
    func runManually(_ task: TokenmaxTask) -> QueueAutoRunDecision.SkipReason? {
        // Clicking the button is approval to run the task, not approval to run
        // it unmetered. Every gate below reads a snapshot that stops refreshing
        // when the provider is switched off, so there is nothing safe to check
        // against and the run is refused.
        guard settingsStore.settings.isEnabled(task.provider) else {
            Log.shared.write("autorun: manual run refused — \(task.provider.rawValue) is switched off")
            return .disabled
        }

        if let reason = QueueAutoRun.manualGate(
            task: task,
            cliInstalled: cliInstalled(task.provider),
            runInFlight: activeRun != nil
        ) {
            Log.shared.write("autorun: manual run refused — \(reason.rawValue)")
            return reason
        }

        // The account gates still apply: a manual run must not be billed either.
        if task.provider == .claudeCode, let gate = QueueAutoRun.accountGate(expensiveGate(force: true)) {
            Log.shared.write("autorun: manual run refused — \(gate.rawValue)")
            return gate
        }

        let windowID = usage.snapshot(for: task.provider)?.sessionWindow?.resetAt
            .map { QueueAutoRun.windowID(resetAt: $0, providerID: task.provider.rawValue) } ?? "autorun-manual"
        run(task, windowID: windowID, trigger: .manual)
        return nil
    }

    /// Continues an earlier run's conversation with a follow-up message.
    ///
    /// A reply is an ordinary manual run that happens to resume: same gates,
    /// same per-turn runtime and budget caps, same record. It is never
    /// automatic — someone typed it — so it does not count against the window's
    /// task budget.
    ///
    /// Note that each turn replays the whole prior conversation as context, so
    /// a long thread costs progressively more; the running total is shown next
    /// to the reply field for exactly that reason.
    @discardableResult
    func reply(to record: TaskRunRecord, text: String) -> QueueAutoRunDecision.SkipReason? {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        guard record.isResumable, let sessionID = record.sessionID else {
            return .notResumable
        }
        // The record carries a copy of the title, but a run needs the live task
        // for its working directory and permission policy — neither of which is
        // safe to reconstruct from a stale copy.
        guard let task = taskStore.tasks.first(where: { $0.id == record.taskID }) else {
            return .taskUnavailable
        }

        if let reason = QueueAutoRun.manualGate(
            task: task,
            cliInstalled: cliInstalled(task.provider),
            runInFlight: activeRun != nil
        ) {
            Log.shared.write("autorun: reply refused — \(reason.rawValue)")
            return reason
        }

        if task.provider == .claudeCode, let gate = QueueAutoRun.accountGate(expensiveGate(force: true)) {
            Log.shared.write("autorun: reply refused — \(gate.rawValue)")
            return gate
        }

        let windowID = usage.snapshot(for: task.provider)?.sessionWindow?.resetAt
            .map { QueueAutoRun.windowID(resetAt: $0, providerID: task.provider.rawValue) } ?? "autorun-manual"
        run(task, windowID: windowID, trigger: .manual, reply: message, resuming: sessionID)
        return nil
    }

    /// Whether a reply could be sent for this run right now, and if not, why.
    /// Drives the disabled state of the reply field rather than letting the user
    /// type a message that will be refused on send.
    func replyBlock(for record: TaskRunRecord) -> QueueAutoRunDecision.SkipReason? {
        guard record.isResumable, record.sessionID != nil else { return .notResumable }
        guard let task = taskStore.tasks.first(where: { $0.id == record.taskID }) else {
            return .taskUnavailable
        }
        return QueueAutoRun.manualGate(
            task: task,
            cliInstalled: cliInstalled(task.provider),
            runInFlight: activeRun != nil
        )
    }

    /// Stops whatever is in flight — the countdown if one is running, otherwise
    /// the process itself.
    func stop() {
        if pendingRun != nil {
            cancelPending()
            return
        }
        guard runTask != nil else { return }
        Log.shared.write("autorun: cancelling active run")
        runTask?.cancel()
    }

    /// Clears a failure pause so the queue can act again in this window.
    func resumeAfterFailure() {
        guard let resetAt = usage.snapshot(for: usage.selectedProvider)?.sessionWindow?.resetAt else { return }
        state.resume(QueueAutoRun.windowID(resetAt: resetAt, providerID: usage.selectedProvider.rawValue))
        persist()
        evaluate()
    }

    // MARK: - Queries for the UI

    /// Why this task cannot run automatically right now, or nil if it can.
    func eligibility(for task: TokenmaxTask) -> QueueAutoRunDecision.SkipReason? {
        let input = makeInput(provider: task.provider)
        return QueueAutoRun.eligibility(
            for: task,
            resetAt: input.sessionWindow?.resetAt,
            settings: input.settings,
            remainingWindowRuntime: QueueAutoRun.remainingWindowRuntime(input),
            now: input.now
        )
    }

    /// The same answer as `eligibility(for:)`, for a whole list, from one
    /// snapshot of the inputs.
    ///
    /// Called per card, `eligibility(for:)` rebuilds `Input` every time — and
    /// building it re-sorts `taskStore.readyTasks`. The queue redraws once a
    /// second, so a five-task queue was doing five sorts a second to answer a
    /// question whose inputs had not changed between them. Same gates, same
    /// pure function, one snapshot.
    ///
    /// Absent from the result means eligible; a value is the reason it is not.
    func eligibilityMap(for tasks: [TokenmaxTask]) -> [UUID: QueueAutoRunDecision.SkipReason] {
        guard !tasks.isEmpty else { return [:] }

        return tasks.reduce(into: [:]) { result, task in
            let input = makeInput(provider: task.provider)
            result[task.id] = QueueAutoRun.eligibility(
                for: task,
                resetAt: input.sessionWindow?.resetAt,
                settings: input.settings,
                remainingWindowRuntime: QueueAutoRun.remainingWindowRuntime(input),
                now: input.now
            )
        }
    }

    func lastRun(forTask taskID: UUID) -> TaskRunRecord? {
        state.mostRecentRun(forTask: taskID)
    }

    /// Every turn of the conversation this run belongs to, oldest first.
    func thread(containing record: TaskRunRecord) -> [TaskRunRecord] {
        state.thread(containing: record)
    }

    var isPausedAfterFailure: Bool {
        decision.skipReason == .pausedAfterFailure
    }

    // MARK: - Notification actions

    private func observeNotificationActions() {
        let center = NotificationCenter.default
        center.addObserver(forName: .tokenmaxAutoRunCancel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        center.addObserver(forName: .tokenmaxAutoRunStartNow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.pendingRun != nil {
                    self.startPendingNow()
                } else {
                    _ = self.runNextEligibleNow()
                }
            }
        }
        // The queue window renders the output itself, so this only has to make
        // sure the window is there to receive the same notification.
        center.addObserver(forName: .tokenmaxAutoRunViewOutput, object: nil, queue: .main) { _ in
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .tokenmaxOpenQueue, object: nil)
            }
        }
    }

    private func persist() {
        JSONStore.save(state, to: FileLocations.queueAutoRunStateFile)

        // Tied to the save rather than to trimming `runs`, so the state stays a
        // pure value type and the sweep also catches transcripts orphaned before
        // this existed. Only a run the state still lists is reachable from the
        // UI; the rest are dead weight holding prompt text and CLI output.
        let removed = FileLocations.pruneRunLogs(keeping: Set(state.runs.map(\.id)))
        if removed > 0 { Log.shared.write("queue: pruned \(removed) orphaned run log(s)") }
    }
}
