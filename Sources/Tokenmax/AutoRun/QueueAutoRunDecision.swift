import Foundation

/// Whether to run a queued task, and if not, exactly why.
///
/// Modelled on `SessionOpenerDecision`, and for the same reason: every
/// suppression is a named case rather than a nested `if`, so it is testable,
/// greppable in the log, and showable in the UI. The stakes are a step higher
/// than the opener's — a wrong `open` spends a little quota, a wrong `run`
/// spends quota *and* edits the user's files — so every ambiguity resolves to
/// `skip`.
enum QueueAutoRunDecision: Equatable, Sendable {
    /// Start it, after the preflight countdown.
    case run(taskID: UUID, windowID: String)
    /// Notify and wait for the user.
    case ask(taskID: UUID, windowID: String)
    /// Eligible, but the mode says do not act.
    case preview(taskID: UUID, windowID: String)
    case skip(reason: SkipReason)

    enum SkipReason: String, Equatable, Sendable, CaseIterable {
        case disabled
        case queueDisabled
        case cliNotInstalled
        /// Cannot currently confirm the quota guards.
        case dataStale
        case noSessionWindow
        /// The session is not close enough to resetting to be worth spending.
        case outsideLeadWindow
        case quietHours
        case sessionQuotaLow
        case weeklyQuotaUnknown
        case weeklyQuotaLow
        /// The account can bill for usage past the plan allowance, and this
        /// feature runs precisely where that allowance ends.
        case extraUsageEnabled
        case extraUsageUnknown
        /// A run is in flight. Tokenmax runs one task at a time, always.
        case runInFlight
        case maximumTasksReached
        case maximumRuntimeReached
        /// A run just finished and the post-run reading has not landed yet.
        case awaitingFreshUsage
        /// The queue was paused by a failure in this window.
        case pausedAfterFailure
        /// The pre-launch run record could not be committed to disk.
        case statePersistenceFailed
        /// Nothing in the queue is marked for automatic execution.
        case noApprovedTask
        /// There are approved tasks, but none can finish before the deadline.
        case insufficientTime

        // Gates that need a subprocess or a file read, applied by the
        // coordinator. Shared verbatim with the session opener: a queued task
        // must not run against pay-as-you-go billing either.
        case notSubscriptionAuth
        case apiKeyConfigured

        // Per-task reasons. Never the top-level verdict on their own — they
        // explain why one card is ineligible while another is not.
        case notApprovedForAutomation
        case workingDirectoryMissing
        case noRuntimeEstimate
        case runtimeExceedsWindowBudget

        /// Only reachable from a reply: run records outlive the tasks they came
        /// from, so a thread can still be open in a sheet after its task has
        /// been deleted.
        case taskUnavailable
        case notResumable

        /// A correct pause the user need not act on, versus something worth
        /// their attention. Drives the colour in Settings and the popover.
        var isNoteworthy: Bool {
            switch self {
            case .disabled, .queueDisabled, .outsideLeadWindow, .quietHours,
                 .runInFlight, .maximumTasksReached, .maximumRuntimeReached,
                 .dataStale, .awaitingFreshUsage, .noApprovedTask:
                false
            default:
                true
            }
        }

        var explanation: String {
            switch self {
            case .disabled:
                "Not enabled."
            case .queueDisabled:
                "The task queue is switched off."
            case .cliNotInstalled:
                "The claude CLI could not be found."
            case .dataStale:
                "Waiting for a fresh usage reading before running anything."
            case .noSessionWindow:
                "No session window is running."
            case .outsideLeadWindow:
                "The session is not close enough to resetting yet."
            case .quietHours:
                "Inside quiet hours."
            case .sessionQuotaLow:
                "Session quota is below your threshold."
            case .weeklyQuotaUnknown:
                "The weekly quota is unknown, so spending cannot be checked."
            case .weeklyQuotaLow:
                "Weekly quota is below your threshold."
            case .extraUsageEnabled:
                "Usage credits are switched on for this account, so a run past the plan allowance would be charged. Turn credits off at claude.ai, or allow them in Settings."
            case .extraUsageUnknown:
                "Cannot tell whether usage credits would be charged, so nothing was started."
            case .runInFlight:
                "A task is already running."
            case .maximumTasksReached:
                "Already ran the maximum number of tasks for this session."
            case .maximumRuntimeReached:
                "Already used the maximum automatic runtime for this session."
            case .awaitingFreshUsage:
                "Waiting for a fresh quota reading after the last task."
            case .pausedAfterFailure:
                "Paused for this session because a task failed."
            case .statePersistenceFailed:
                "The run record could not be saved, so nothing was started. Restart Tokenmax after checking free disk space and folder permissions."
            case .noApprovedTask:
                "No queued task is marked for automatic execution."
            case .insufficientTime:
                "Not enough time left before the reset to finish a task safely."
            case .notSubscriptionAuth:
                "Claude Code is not signed in to a Claude subscription."
            case .apiKeyConfigured:
                "An API key is configured in ~/.claude/settings.json, so a run would be billed."
            case .notApprovedForAutomation:
                "Not marked for automatic execution."
            case .workingDirectoryMissing:
                "The working directory does not exist."
            case .noRuntimeEstimate:
                "No estimated runtime has been set."
            case .runtimeExceedsWindowBudget:
                "Its runtime limit is longer than the remaining automatic runtime for this session."
            case .taskUnavailable:
                "The task this run came from no longer exists."
            case .notResumable:
                "This run's conversation was not saved, so it cannot be continued."
            }
        }
    }

    var taskID: UUID? {
        switch self {
        case let .run(taskID, _), let .ask(taskID, _), let .preview(taskID, _): taskID
        case .skip: nil
        }
    }

    var windowID: String? {
        switch self {
        case let .run(_, windowID), let .ask(_, windowID), let .preview(_, windowID): windowID
        case .skip: nil
        }
    }

    var skipReason: SkipReason? {
        switch self {
        case .skip(let reason): reason
        default: nil
        }
    }

    /// True when a task was found eligible, whatever the mode then decided.
    var isEligible: Bool { taskID != nil }
}

/// The pure half of the queue auto-runner. No processes, no network, no clock of
/// its own — everything arrives in `Input`, so every guard is directly testable.
enum QueueAutoRun {
    struct Input {
        /// The provider whose quota window and tasks are being evaluated.
        /// It also namespaces persisted per-window limits so simultaneous
        /// provider resets cannot share a task/runtime allowance.
        var providerID: String
        var settings: QueueAutoRunSettings
        var queueEnabled: Bool
        var quietHours: QuietHours
        var sessionWindow: UsageWindow?
        var weeklyWindow: UsageWindow?
        /// Whether the account bills for usage past the plan allowance. nil is
        /// "unknown", not "no" — the provider may not report it at all.
        var extraUsageEnabled: Bool?
        var isStale: Bool
        var cliInstalled: Bool
        /// Ready tasks in queue order. `TaskStore.readyTasks` already sorts by
        /// manual order, then priority, then age.
        var tasks: [TokenmaxTask]
        var state: QueueAutoRunState
        /// True while a run is in flight, which the state file cannot tell us:
        /// a `.running` record could equally be an abandoned one.
        var runInFlight: Bool
        /// Set after a run completes, until a reading newer than it arrives.
        var awaitingFreshUsage: Bool
        var now: Date

        init(
            providerID: String = TokenmaxProvider.claudeCode.rawValue,
            settings: QueueAutoRunSettings,
            queueEnabled: Bool = true,
            quietHours: QuietHours = .init(),
            sessionWindow: UsageWindow?,
            weeklyWindow: UsageWindow?,
            extraUsageEnabled: Bool? = false,
            isStale: Bool = false,
            cliInstalled: Bool = true,
            tasks: [TokenmaxTask] = [],
            state: QueueAutoRunState = .init(),
            runInFlight: Bool = false,
            awaitingFreshUsage: Bool = false,
            now: Date = Date()
        ) {
            self.providerID = providerID
            self.settings = settings
            self.queueEnabled = queueEnabled
            self.quietHours = quietHours
            self.sessionWindow = sessionWindow
            self.weeklyWindow = weeklyWindow
            self.extraUsageEnabled = extraUsageEnabled
            self.isStale = isStale
            self.cliInstalled = cliInstalled
            self.tasks = tasks
            self.state = state
            self.runInFlight = runInFlight
            self.awaitingFreshUsage = awaitingFreshUsage
            self.now = now
        }
    }

    /// Identifies the session window a run belongs to.
    ///
    /// Bucketed with the same 300s bucket the reminder identifiers and
    /// `SessionOpener.cycleID` use, for the same reason: the reset timestamp the
    /// endpoint reports jitters by a second or so between fetches, and an
    /// unbucketed key would reset the per-window task counter on every jitter —
    /// turning "one task per window" into one task per refresh.
    static func windowID(
        resetAt: Date,
        providerID: String = TokenmaxProvider.claudeCode.rawValue
    ) -> String {
        let bucket = NotificationScheduler.identifierBucket
        let bucketed = Date(
            timeIntervalSince1970: (resetAt.timeIntervalSince1970 / bucket).rounded() * bucket
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Preserve existing Claude state files while keeping Codex windows
        // independent when the two providers happen to reset together.
        let prefix = providerID == TokenmaxProvider.claudeCode.rawValue ? "autorun-" : "autorun-\(providerID)-"
        return prefix + formatter.string(from: bucketed)
    }

    // MARK: - Time budget

    /// The last moment a new task may start and still be expected to finish
    /// inside the window that is paying for it.
    static func effectiveDeadline(resetAt: Date, settings: QueueAutoRunSettings) -> Date {
        resetAt.addingTimeInterval(-Double(settings.safetyMarginMinutes) * 60)
    }

    /// The latest `now` at which `task` may start.
    ///
    /// Budgeted against the task's *hard runtime ceiling*, not its estimate.
    /// The runner terminates the process at `maximumRuntimeMinutes`, so that is
    /// the real worst case; budgeting on a 12-minute estimate would happily
    /// start a task allowed to run for 30 minutes with 13 minutes to go.
    static func latestStart(
        for task: TokenmaxTask,
        resetAt: Date,
        settings: QueueAutoRunSettings
    ) -> Date {
        effectiveDeadline(resetAt: resetAt, settings: settings)
            .addingTimeInterval(-Double(task.maximumRuntimeMinutes) * 60)
    }

    // MARK: - Per-task eligibility

    /// Why this task cannot be run automatically right now, or nil if it can.
    ///
    /// Separate from `decide` so each queue card can explain itself, rather than
    /// the user seeing one global "no eligible task" and having to guess which
    /// of five tasks is the problem.
    static func eligibility(
        for task: TokenmaxTask,
        resetAt: Date?,
        settings: QueueAutoRunSettings,
        remainingWindowRuntime: TimeInterval? = nil,
        now: Date = Date()
    ) -> QueueAutoRunDecision.SkipReason? {
        guard task.status == .ready else { return .notApprovedForAutomation }
        if settings.onlyRunApprovedTasks, task.executionMode != .automatic {
            return .notApprovedForAutomation
        }
        guard task.workingDirectoryExists else { return .workingDirectoryMissing }
        // Required even though the budget uses the ceiling: a task nobody has
        // sized is a task nobody has thought about running unattended.
        guard task.estimatedMinutes != nil else { return .noRuntimeEstimate }

        if let remainingWindowRuntime,
           Double(task.maximumRuntimeMinutes) * 60 > remainingWindowRuntime
        {
            return .runtimeExceedsWindowBudget
        }

        if let resetAt, now > latestStart(for: task, resetAt: resetAt, settings: settings) {
            return .insufficientTime
        }

        return nil
    }

    /// The first task that could be run, in queue order.
    static func nextEligibleTask(_ input: Input) -> TokenmaxTask? {
        let remaining = remainingWindowRuntime(input)
        return input.tasks.first { task in
            eligibility(
                for: task,
                resetAt: input.sessionWindow?.resetAt,
                settings: input.settings,
                remainingWindowRuntime: remaining,
                now: input.now
            ) == nil
        }
    }

    /// Every task the user has approved for automation, eligible or not. Used to
    /// tell "you have none" apart from "you have some, but not now".
    static func approvedTasks(_ input: Input) -> [TokenmaxTask] {
        input.tasks.filter { task in
            task.status == .ready
                && (!input.settings.onlyRunApprovedTasks || task.executionMode == .automatic)
        }
    }

    static func remainingWindowRuntime(_ input: Input) -> TimeInterval? {
        guard let resetAt = input.sessionWindow?.resetAt else { return nil }
        let used = input.state.totalRuntime(
            inWindow: windowID(resetAt: resetAt, providerID: input.providerID), now: input.now
        )
        return max(0, Double(input.settings.maximumRuntimeMinutes) * 60 - used)
    }

    // MARK: - The decision

    /// Every guard that can be decided from data already in hand.
    ///
    /// Ordering matters in one place: `dataStale` comes before anything that
    /// reads a quota number, because the whole point of that check is that those
    /// numbers cannot currently be trusted.
    static func decide(_ input: Input) -> QueueAutoRunDecision {
        let settings = input.settings

        guard settings.enabled else { return .skip(reason: .disabled) }
        guard input.queueEnabled else { return .skip(reason: .queueDisabled) }
        guard input.cliInstalled else { return .skip(reason: .cliNotInstalled) }

        // One at a time, always — before anything else, because a second run
        // must be refused whatever the quota happens to look like.
        guard !input.runInFlight else { return .skip(reason: .runInFlight) }

        if settings.requireFreshUsageData {
            guard !input.isStale else { return .skip(reason: .dataStale) }
            guard !input.awaitingFreshUsage else { return .skip(reason: .awaitingFreshUsage) }
        }

        guard let session = input.sessionWindow, let resetAt = session.resetAt, !session.hasNotStarted else {
            return .skip(reason: .noSessionWindow)
        }

        let window = windowID(resetAt: resetAt, providerID: input.providerID)

        if input.state.isPaused(window) { return .skip(reason: .pausedAfterFailure) }

        // Inside the burn window? This is the auto-runner's own lead time, not
        // the reminder's — see `QueueAutoRunSettings`.
        let timeUntilReset = resetAt.timeIntervalSince(input.now)
        guard timeUntilReset <= Double(settings.leadTimeMinutes) * 60 else {
            return .skip(reason: .outsideLeadWindow)
        }

        if settings.respectQuietHours, input.quietHours.contains(input.now) {
            return .skip(reason: .quietHours)
        }

        // Per-window budgets, before the quota checks: they are cheaper and
        // their explanations are more useful when both would fire.
        let automaticRuns = input.state.automaticRuns(inWindow: window)
        guard automaticRuns.count < settings.maximumTasksPerWindow else {
            return .skip(reason: .maximumTasksReached)
        }
        let remainingRuntime = max(
            0,
            Double(settings.maximumRuntimeMinutes) * 60
                - input.state.totalRuntime(inWindow: window, now: input.now)
        )
        guard remainingRuntime > 0 else { return .skip(reason: .maximumRuntimeReached) }

        guard let sessionRemaining = session.remainingPercent,
              sessionRemaining >= settings.minimumSessionRemainingPercent
        else {
            return .skip(reason: .sessionQuotaLow)
        }

        // The five-hour and weekly allowances share one budget, so a run is
        // never free of the weekly one.
        guard let weeklyRemaining = input.weeklyWindow?.remainingPercent else {
            return .skip(reason: .weeklyQuotaUnknown)
        }
        guard weeklyRemaining >= settings.minimumWeeklyRemainingPercent else {
            return .skip(reason: .weeklyQuotaLow)
        }

        // Categorical where the thresholds above are numeric, and it holds even
        // if the reported percentages are wrong. Shares its wording and its
        // "silence is not consent" rule with the opener's copy of this gate:
        // unknown is refused rather than assumed off, and because that would
        // otherwise be an invisible dead end, Settings names the reason and
        // offers the toggle as the way out.
        if settings.skipWhenExtraUsageEnabled {
            guard let extra = input.extraUsageEnabled else { return .skip(reason: .extraUsageUnknown) }
            if extra { return .skip(reason: .extraUsageEnabled) }
        }

        guard let task = nextEligibleTask(input) else {
            // Distinguish "nothing is approved" from "something is approved but
            // will not fit". They need different fixes from the user.
            return .skip(reason: approvedTasks(input).isEmpty ? .noApprovedTask : .insufficientTime)
        }

        switch settings.mode {
        case .previewOnly: return .preview(taskID: task.id, windowID: window)
        case .askBeforeRunning: return .ask(taskID: task.id, windowID: window)
        case .automatic: return .run(taskID: task.id, windowID: window)
        }
    }

    // MARK: - Manual trigger

    /// The guards a hand-triggered run still has to pass.
    ///
    /// The manual path bypasses the *schedule* — lead window, countdown,
    /// per-window caps, quota thresholds, and the execution-mode gate, since
    /// clicking the button is itself the approval — but never the conditions
    /// that would make a run unsafe or impossible. Mirrors
    /// `SessionOpenerCoordinator.sendNow`, which bypasses timing and nothing else.
    static func manualGate(
        task: TokenmaxTask,
        cliInstalled: Bool,
        runInFlight: Bool
    ) -> QueueAutoRunDecision.SkipReason? {
        if !cliInstalled { return .cliNotInstalled }
        if runInFlight { return .runInFlight }
        if !task.workingDirectoryExists { return .workingDirectoryMissing }
        return nil
    }

    /// Translates the session opener's account gates into this feature's
    /// vocabulary. The checks are shared; only the enum differs.
    static func accountGate(_ reason: SessionOpenerDecision.SkipReason?) -> QueueAutoRunDecision.SkipReason? {
        switch reason {
        case .none: nil
        case .apiKeyConfigured: .apiKeyConfigured
        default: .notSubscriptionAuth
        }
    }
}
