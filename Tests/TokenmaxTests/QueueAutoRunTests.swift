import Foundation
import Testing

@testable import Tokenmax

@Suite("Queue auto-run")
struct QueueAutoRunTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    /// A directory that certainly exists, so `workingDirectoryExists` is not the
    /// thing under test in every case.
    private var realDirectory: String { NSTemporaryDirectory() }

    // MARK: - Builders

    private func session(resetInMinutes: Double = 30, remaining: Double = 60) -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: .session,
            label: "Session",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(resetInMinutes * 60),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    /// The default reset is a day out, which is far outside any lead time — so
    /// a test that does not care about the weekly window cannot accidentally
    /// have it picked as the window to burn.
    private func weekly(remaining: Double = 80, resetInMinutes: Double = 1440) -> UsageWindow {
        UsageWindow(
            id: "claude.weekly",
            kind: .weekly,
            label: "Weekly",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(resetInMinutes * 60),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func task(
        title: String = "Generate API tests",
        mode: ExecutionMode = .automatic,
        estimate: Int? = 10,
        runtimeCap: Int = 15,
        directory: String? = nil,
        status: TaskStatus = .ready,
        sortIndex: Double = 0,
        scheduledStart: Date? = nil
    ) -> TokenmaxTask {
        var task = TokenmaxTask(
            title: title,
            prompt: "Do the thing.",
            workingDirectory: directory ?? realDirectory,
            status: status,
            executionMode: mode,
            sortIndex: sortIndex
        )
        task.estimatedMinutes = estimate
        task.autoRun.maximumRuntimeMinutes = runtimeCap
        task.scheduledStart = scheduledStart
        return task
    }

    /// A task dated `minutes` from the fixed `now`. Negative is in the past.
    private func scheduled(minutesFromNow minutes: Double, estimate: Int? = 10) -> TokenmaxTask {
        task(estimate: estimate, scheduledStart: now.addingTimeInterval(minutes * 60))
    }

    private func settings(
        enabled: Bool = true,
        mode: QueueAutoRunMode = .automatic,
        leadTimeMinutes: Int = 45,
        minimumSession: Double = 25,
        minimumWeekly: Double = 10,
        safetyMarginMinutes: Int = 10,
        maximumTasks: Int = 1,
        maximumRuntime: Int = 30,
        onlyApproved: Bool = true,
        requireFresh: Bool = true,
        respectQuietHours: Bool = true,
        skipWhenExtraUsage: Bool = true
    ) -> QueueAutoRunSettings {
        var settings = QueueAutoRunSettings()
        settings.enabled = enabled
        settings.mode = mode
        settings.leadTimeMinutes = leadTimeMinutes
        settings.minimumSessionRemainingPercent = minimumSession
        settings.minimumWeeklyRemainingPercent = minimumWeekly
        settings.safetyMarginMinutes = safetyMarginMinutes
        settings.maximumTasksPerWindow = maximumTasks
        settings.maximumRuntimeMinutes = maximumRuntime
        settings.onlyRunApprovedTasks = onlyApproved
        settings.requireFreshUsageData = requireFresh
        settings.respectQuietHours = respectQuietHours
        settings.skipWhenExtraUsageEnabled = skipWhenExtraUsage
        return settings
    }

    /// Everything lined up so a task runs. Each test spoils exactly one thing,
    /// so a failure names its own cause.
    private func input(
        settings: QueueAutoRunSettings? = nil,
        queueEnabled: Bool = true,
        quietHours: QuietHours = .init(),
        session: UsageWindow? = nil,
        /// Explicit rather than `session: nil`, which the `??` below would
        /// quietly turn back into the default window.
        noSessionWindow: Bool = false,
        weeklyRemaining: Double? = 80,
        weeklyResetInMinutes: Double = 1440,
        burnFallsBackToWeekly: Bool = false,
        providerID: String = TokenmaxProvider.claudeCode.rawValue,
        extraUsageEnabled: Bool? = false,
        isStale: Bool = false,
        cliInstalled: Bool = true,
        tasks: [TokenmaxTask]? = nil,
        state: QueueAutoRunState = .init(),
        runInFlight: Bool = false,
        awaitingFreshUsage: Bool = false,
        now: Date? = nil
    ) -> QueueAutoRun.Input {
        QueueAutoRun.Input(
            providerID: providerID,
            settings: settings ?? self.settings(),
            queueEnabled: queueEnabled,
            quietHours: quietHours,
            sessionWindow: noSessionWindow ? nil : (session ?? self.session()),
            weeklyWindow: weeklyRemaining.map {
                weekly(remaining: $0, resetInMinutes: weeklyResetInMinutes)
            },
            burnFallsBackToWeekly: burnFallsBackToWeekly,
            extraUsageEnabled: extraUsageEnabled,
            isStale: isStale,
            cliInstalled: cliInstalled,
            tasks: tasks ?? [task()],
            state: state,
            runInFlight: runInFlight,
            awaitingFreshUsage: awaitingFreshUsage,
            now: now ?? self.now
        )
    }

    private func skipReason(_ input: QueueAutoRun.Input) -> QueueAutoRunDecision.SkipReason? {
        QueueAutoRun.decide(input).skipReason
    }

    // MARK: - The happy path

    @Test("A task never launches when its starting record cannot be saved")
    @MainActor
    func persistenceFailureFailsClosed() {
        let record = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Never launch",
            windowID: "window",
            trigger: .automatic,
            providerID: ClaudeCodeProvider.providerID,
            model: "sonnet",
            workingDirectory: realDirectory
        )
        var didLaunch = false

        let launched = QueueAutoRunCoordinator.recordAndLaunchIfPersisted(
            state: QueueAutoRunState(),
            record: record,
            persist: { _ in false }
        ) { _ in
            didLaunch = true
        }

        #expect(!launched)
        #expect(!didLaunch)
    }

    @Test("Runs an approved task inside the lead window")
    func runsApprovedTask() throws {
        let queued = task()
        let decision = QueueAutoRun.decide(input(tasks: [queued]))
        #expect(decision.taskID == queued.id)
        if case .run = decision {} else { Issue.record("expected .run, got \(decision)") }
    }

    @Test("Mode decides what an eligible task turns into")
    func modeSelectsOutcome() {
        let queued = task()

        let preview = QueueAutoRun.decide(input(settings: settings(mode: .previewOnly), tasks: [queued]))
        if case .preview = preview {} else { Issue.record("expected .preview, got \(preview)") }

        let ask = QueueAutoRun.decide(input(settings: settings(mode: .askBeforeRunning), tasks: [queued]))
        if case .ask = ask {} else { Issue.record("expected .ask, got \(ask)") }

        // Every mode still finds the same task — the mode changes what happens
        // next, never whether the guards passed.
        #expect(preview.taskID == queued.id)
        #expect(ask.taskID == queued.id)
    }

    // MARK: - Global guards

    @Test("Off by default, and disabled means disabled")
    func disabledByDefault() {
        #expect(QueueAutoRunSettings().enabled == false)
        #expect(QueueAutoRunSettings().mode == .previewOnly)
        #expect(skipReason(input(settings: settings(enabled: false))) == .disabled)
    }

    @Test("Switching the queue off stops automation with it")
    func queueDisabled() {
        #expect(skipReason(input(queueEnabled: false)) == .queueDisabled)
    }

    @Test("No CLI, no run")
    func cliMissing() {
        #expect(skipReason(input(cliInstalled: false)) == .cliNotInstalled)
    }

    @Test("A run in flight blocks everything, whatever the quota looks like")
    func runInFlightWins() {
        // Deliberately paired with a quota that would otherwise fail: one task
        // at a time is not negotiable against a *different* skip reason.
        let reason = skipReason(input(session: session(remaining: 5), runInFlight: true))
        #expect(reason == .runInFlight)
    }

    @Test("Stale data is a hard stop, and comes before any quota check")
    func staleData() {
        // Session quota is far below the threshold; staleness must still win,
        // because the number it would be judged against cannot be trusted.
        let reason = skipReason(input(session: session(remaining: 1), isStale: true))
        #expect(reason == .dataStale)
    }

    @Test("Staleness can be switched off, and then the quota check runs")
    func staleAllowedWhenNotRequired() {
        let reason = skipReason(input(settings: settings(requireFresh: false), isStale: true))
        #expect(reason == nil)
    }

    @Test("Nothing runs on a snapshot older than the last task")
    func awaitingFreshUsage() {
        #expect(skipReason(input(awaitingFreshUsage: true)) == .awaitingFreshUsage)
    }

    @Test("A session that has not started is not a window to spend")
    func noSessionWindow() {
        #expect(skipReason(input(noSessionWindow: true)) == .noSessionWindow)
    }

    @Test("Outside the lead window, nothing is eligible")
    func outsideLeadWindow() {
        let reason = skipReason(input(session: session(resetInMinutes: 200)))
        #expect(reason == .outsideLeadWindow)
    }

    @Test("Quiet hours suppress automation, and can be ignored")
    func quietHours() {
        let quiet = QuietHours(enabled: true, startMinutes: 0, endMinutes: 24 * 60 - 1)
        #expect(skipReason(input(quietHours: quiet)) == .quietHours)
        #expect(skipReason(input(settings: settings(respectQuietHours: false), quietHours: quiet)) == nil)
    }

    // MARK: - Quota guards

    @Test("Session quota below the threshold stops the run")
    func sessionQuotaLow() {
        #expect(skipReason(input(session: session(remaining: 10))) == .sessionQuotaLow)
    }

    @Test("An unknown weekly quota is refused, not assumed fine")
    func weeklyUnknown() {
        #expect(skipReason(input(weeklyRemaining: nil)) == .weeklyQuotaUnknown)
    }

    @Test("Weekly quota below the threshold stops the run")
    func weeklyQuotaLow() {
        #expect(skipReason(input(weeklyRemaining: 5)) == .weeklyQuotaLow)
    }

    // MARK: - Time budget

    @Test("The budget uses the runtime ceiling, not the estimate")
    func budgetUsesRuntimeCeiling() {
        // 30 minutes to reset, 10 minute safety margin, so the effective
        // deadline is 20 minutes out. A task estimated at 5 minutes but capped
        // at 25 must NOT start: the cap is what the runner actually enforces,
        // and budgeting on the estimate is how a task overruns the window.
        let optimistic = task(estimate: 5, runtimeCap: 25)
        #expect(skipReason(input(tasks: [optimistic])) == .insufficientTime)

        // Same estimate, honest cap — fits with 5 minutes to spare.
        let honest = task(estimate: 5, runtimeCap: 15)
        #expect(skipReason(input(tasks: [honest])) == nil)
    }

    @Test("latestStart is exactly deadline minus the runtime ceiling")
    func latestStartArithmetic() {
        let resetAt = now.addingTimeInterval(30 * 60)
        let rule = settings(safetyMarginMinutes: 10)
        let queued = task(runtimeCap: 15)

        let deadline = QueueAutoRun.effectiveDeadline(resetAt: resetAt, settings: rule)
        #expect(deadline == resetAt.addingTimeInterval(-600))

        let latest = QueueAutoRun.latestStart(for: queued, resetAt: resetAt, settings: rule)
        #expect(latest == deadline.addingTimeInterval(-900))
    }

    @Test("The boundary is inclusive on one side and not the other")
    func latestStartBoundary() {
        let queued = task(runtimeCap: 15)
        let resetAt = now.addingTimeInterval(30 * 60)
        let rule = settings(safetyMarginMinutes: 10)
        let latest = QueueAutoRun.latestStart(for: queued, resetAt: resetAt, settings: rule)

        // Exactly at the last possible moment: allowed.
        #expect(QueueAutoRun.eligibility(
            for: queued, resetAt: resetAt, settings: rule, now: latest
        ) == nil)

        // One second later: refused.
        #expect(QueueAutoRun.eligibility(
            for: queued, resetAt: resetAt, settings: rule, now: latest.addingTimeInterval(1)
        ) == .insufficientTime)
    }

    // MARK: - Working directory permission

    // The probe must exercise a *file read*. Listing is not what TCC gates, so
    // both an `open(O_DIRECTORY)` and a `readdir` probe reported success on a
    // folder with no permission — which is how this shipped broken twice.
    //
    // TCC's own denial (`EPERM`) cannot be simulated in a unit test: `chmod`
    // produces `EACCES`, which the probe deliberately treats differently. What
    // is testable is that the probe reads a file at all, and that ordinary Unix
    // permissions never masquerade as a TCC denial.

    @Test("A folder that cannot even be listed is unreadable")
    func unlistableDirectoryIsUnreadable() throws {
        let blocked = task(directory: "/var/root")
        try #require(blocked.workingDirectoryExists, "precondition: /var/root must exist")
        try #require(getuid() != 0, "precondition: not root")
        #expect(!blocked.workingDirectoryReadable)
    }

    @Test("One unreadable file does not condemn the whole folder")
    func unixPermissionsAreNotATCCDenial() throws {
        // `EACCES` on a single file says nothing about the folder. Treating it
        // as a denial would refuse to run a task over one lock file.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenmax-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "locked".write(to: root.appendingPathComponent("a-locked.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("a-locked.txt").path
        )
        try "fine".write(to: root.appendingPathComponent("b-open.txt"), atomically: true, encoding: .utf8)

        #expect(task(directory: root.path).workingDirectoryReadable)
    }

    @Test("A folder holding only subdirectories is not reported as blocked")
    func directoryWithNoFilesIsReadable() throws {
        // Nothing to test against is not the same as a refusal, and refusing
        // here would block a run over a question that could not be asked.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tokenmax-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(task(directory: root.path).workingDirectoryReadable)
    }

    @Test("A readable folder is not mistaken for a blocked one")
    func readableDirectoryIsAllowed() {
        #expect(task().workingDirectoryReadable)
    }

    @Test("One dialog per directory, not one per task")
    func accessProbeDeduplicatesDirectories() {
        // Three tasks in one checkout must not raise three consent dialogs.
        let shared = [task(title: "a"), task(title: "b"), task(title: "c")]
        #expect(WorkingDirectoryAccess.distinctExistingDirectories(in: shared).count == 1)
    }

    @Test("A missing directory is never probed")
    func accessProbeSkipsMissingDirectories() {
        // Asking macOS about a path the user has mistyped would raise a
        // permission dialog for a folder that does not exist.
        let missing = [task(directory: "/nope/does/not/exist")]
        #expect(WorkingDirectoryAccess.distinctExistingDirectories(in: missing).isEmpty)
    }

    // MARK: - Per-window budgets

    @Test("One task per window, keyed on the bucketed reset time")
    func maximumTasksPerWindow() {
        let resetAt = now.addingTimeInterval(30 * 60)
        var state = QueueAutoRunState()
        var previous = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Earlier task",
            windowID: QueueAutoRun.windowID(resetAt: resetAt),
            trigger: .automatic,
            startedAt: now.addingTimeInterval(-600),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .completed
        )
        previous.finishedAt = now.addingTimeInterval(-300)
        state.record(previous)

        #expect(skipReason(input(state: state)) == .maximumTasksReached)
    }

    @Test("A manual run does not consume the window's task budget")
    func manualRunsDoNotCount() {
        // Otherwise testing the runner by hand would switch off the automation
        // you are testing, for the rest of the session.
        let resetAt = now.addingTimeInterval(30 * 60)
        var state = QueueAutoRunState()
        var manual = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Hand-triggered",
            windowID: QueueAutoRun.windowID(resetAt: resetAt),
            trigger: .manual,
            startedAt: now.addingTimeInterval(-600),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .completed
        )
        manual.finishedAt = now.addingTimeInterval(-300)
        state.record(manual)

        #expect(skipReason(input(state: state)) == nil)
    }

    @Test("A one-second jitter in the reset time is the same window")
    func windowIDBucketing() {
        // The endpoint's reset timestamp drifts between fetches. Without
        // bucketing, "one task per window" would silently become one per fetch.
        let a = QueueAutoRun.windowID(resetAt: now)
        let b = QueueAutoRun.windowID(resetAt: now.addingTimeInterval(1))
        #expect(a == b)

        let far = QueueAutoRun.windowID(resetAt: now.addingTimeInterval(3600))
        #expect(a != far)
    }

    @Test("The window's total runtime budget is enforced")
    func maximumRuntimePerWindow() {
        let resetAt = now.addingTimeInterval(30 * 60)
        var state = QueueAutoRunState()
        var long = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Long one",
            windowID: QueueAutoRun.windowID(resetAt: resetAt),
            trigger: .automatic,
            startedAt: now.addingTimeInterval(-31 * 60),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .completed
        )
        long.finishedAt = now
        state.record(long)

        // Two tasks allowed, but the 30-minute runtime budget is already spent.
        let rule = settings(maximumTasks: 2, maximumRuntime: 30)
        #expect(skipReason(input(settings: rule, state: state)) == .maximumRuntimeReached)
    }

    @Test("A failure pauses the queue for that window only")
    func pausedAfterFailure() {
        let resetAt = now.addingTimeInterval(30 * 60)
        var state = QueueAutoRunState()
        state.pause(QueueAutoRun.windowID(resetAt: resetAt))
        #expect(skipReason(input(state: state)) == .pausedAfterFailure)

        state.resume(QueueAutoRun.windowID(resetAt: resetAt))
        #expect(skipReason(input(state: state)) == nil)
    }

    // MARK: - Candidate selection

    @Test("Unapproved tasks are never run automatically")
    func onlyApprovedTasksRun() {
        let manual = task(mode: .manual)
        #expect(skipReason(input(tasks: [manual])) == .noApprovedTask)
        #expect(QueueAutoRun.eligibility(
            for: manual, resetAt: now.addingTimeInterval(1800), settings: settings()
        ) == .notApprovedForAutomation)
    }

    @Test("'No approved task' is distinct from 'none fits right now'")
    func noApprovedVersusInsufficientTime() {
        // The two need different fixes from the user, so they must not collapse
        // into one message.
        #expect(skipReason(input(tasks: [task(mode: .manual)])) == .noApprovedTask)
        #expect(skipReason(input(tasks: [task(estimate: 5, runtimeCap: 60)])) == .insufficientTime)
    }

    @Test("A missing working directory makes a task ineligible")
    func workingDirectoryMissing() {
        let broken = task(directory: "/definitely/not/here-\(UUID().uuidString)")
        #expect(QueueAutoRun.eligibility(
            for: broken, resetAt: now.addingTimeInterval(1800), settings: settings()
        ) == .workingDirectoryMissing)
        #expect(skipReason(input(tasks: [broken])) == .insufficientTime)
    }

    @Test("A task with no estimate is not run unattended")
    func estimateRequired() {
        let unsized = task(estimate: nil)
        #expect(QueueAutoRun.eligibility(
            for: unsized, resetAt: now.addingTimeInterval(1800), settings: settings()
        ) == .noRuntimeEstimate)
    }

    @Test("Only ready tasks are candidates")
    func onlyReadyTasks() {
        for status in [TaskStatus.running, .completed, .needsAttention, .archived] {
            let other = task(status: status)
            #expect(QueueAutoRun.eligibility(
                for: other, resetAt: now.addingTimeInterval(1800), settings: settings()
            ) == .notApprovedForAutomation)
        }
    }

    @Test("The first eligible task in queue order wins")
    func picksFirstEligible() throws {
        // Queue order first: the blocked task sorts ahead, so choosing the
        // second proves ineligible candidates are skipped rather than stopping
        // the search.
        let blocked = task(title: "Blocked", directory: "/nope-\(UUID().uuidString)", sortIndex: 0)
        let good = task(title: "Good", sortIndex: 1)
        let later = task(title: "Later", sortIndex: 2)

        let chosen = try #require(QueueAutoRun.nextEligibleTask(input(tasks: [blocked, good, later])))
        #expect(chosen.id == good.id)
    }

    @Test("A task longer than the window's remaining runtime is skipped")
    func runtimeExceedsWindowBudget() {
        let resetAt = now.addingTimeInterval(30 * 60)
        var state = QueueAutoRunState()
        var used = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Used 20 minutes",
            windowID: QueueAutoRun.windowID(resetAt: resetAt),
            trigger: .automatic,
            startedAt: now.addingTimeInterval(-20 * 60),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .completed
        )
        used.finishedAt = now
        state.record(used)

        // 10 minutes of the 30-minute window budget left; a 15-minute cap does
        // not fit.
        let rule = settings(maximumTasks: 3, maximumRuntime: 30)
        let queued = task(runtimeCap: 15)
        let remaining = QueueAutoRun.remainingWindowRuntime(
            input(settings: rule, tasks: [queued], state: state)
        )
        #expect(QueueAutoRun.eligibility(
            for: queued,
            resetAt: resetAt,
            settings: rule,
            remainingWindowRuntime: remaining,
            now: now
        ) == .runtimeExceedsWindowBudget)
    }

    // MARK: - Manual trigger

    @Test("The manual gate ignores execution mode but not the directory")
    func manualGateChecks() {
        // Pressing the button is the approval, so `.manual` must not block it —
        // otherwise the safe default could never be tested before being trusted.
        let unapproved = task(mode: .manual)
        #expect(QueueAutoRun.manualGate(task: unapproved, cliInstalled: true, runInFlight: false) == nil)

        let broken = task(directory: "/gone-\(UUID().uuidString)")
        #expect(QueueAutoRun.manualGate(task: broken, cliInstalled: true, runInFlight: false)
            == .workingDirectoryMissing)
        #expect(QueueAutoRun.manualGate(task: unapproved, cliInstalled: false, runInFlight: false)
            == .cliNotInstalled)
        #expect(QueueAutoRun.manualGate(task: unapproved, cliInstalled: true, runInFlight: true)
            == .runInFlight)
    }

    @Test("Account gates map onto this feature's reasons")
    func accountGateMapping() {
        #expect(QueueAutoRun.accountGate(nil) == nil)
        #expect(QueueAutoRun.accountGate(.apiKeyConfigured) == .apiKeyConfigured)
        #expect(QueueAutoRun.accountGate(.notSubscriptionAuth) == .notSubscriptionAuth)
    }

    // MARK: - State bookkeeping

    @Test("Cancelling does not pause the queue; failing does")
    func onlyRealFailuresPauseTheQueue() {
        // Stopping one task by hand must not silently stop the rest, which is
        // the opposite of what the user just asked for.
        #expect(TaskRunStatus.cancelled.pausesQueue == false)
        #expect(TaskRunStatus.budgetExceeded.pausesQueue == false)
        #expect(TaskRunStatus.completed.pausesQueue == false)
        #expect(TaskRunStatus.failed.pausesQueue)
        #expect(TaskRunStatus.timedOut.pausesQueue)
        #expect(TaskRunStatus.interrupted.pausesQueue)
    }

    @Test("Only starting and running count as unfinished")
    func unfinishedRuns() {
        var state = QueueAutoRunState()
        for status in TaskRunStatus.allCases {
            var run = TaskRunRecord(
                taskID: UUID(),
                taskTitle: status.rawValue,
                windowID: "w",
                trigger: .automatic,
                model: "sonnet",
                workingDirectory: realDirectory,
                status: status
            )
            run.finishedAt = status.isFinished ? Date() : nil
            state.record(run)
        }
        #expect(Set(state.unfinishedRuns.map(\.status)) == [.starting, .running])
    }

    @Test("An in-flight run counts against the window's runtime as it goes")
    func unfinishedRunCountsTowardsRuntime() {
        // Otherwise a long task could outrun the window budget simply by not
        // having ended yet.
        var state = QueueAutoRunState()
        state.record(TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Still going",
            windowID: "w",
            trigger: .automatic,
            startedAt: now.addingTimeInterval(-600),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .running
        ))
        #expect(state.totalRuntime(inWindow: "w", now: now) == 600)
    }

    @Test("The run history stays bounded")
    func historyIsBounded() {
        var state = QueueAutoRunState()
        for index in 0 ..< 60 {
            state.record(TaskRunRecord(
                taskID: UUID(),
                taskTitle: "Run \(index)",
                windowID: "w",
                trigger: .automatic,
                startedAt: now.addingTimeInterval(Double(index)),
                model: "sonnet",
                workingDirectory: realDirectory,
                status: .completed
            ))
        }
        #expect(state.runs.count == 40)
        #expect(state.runs.last?.taskTitle == "Run 59")
    }

    // MARK: - Conversation threads

    /// A run in `session`, started `offset` seconds from `now`.
    private func threadRun(
        _ title: String,
        session: String?,
        offset: TimeInterval,
        taskID: UUID = UUID()
    ) -> TaskRunRecord {
        var run = TaskRunRecord(
            taskID: taskID,
            taskTitle: title,
            windowID: "w",
            trigger: .manual,
            startedAt: now.addingTimeInterval(offset),
            model: "sonnet",
            workingDirectory: realDirectory,
            status: .completed
        )
        run.sessionID = session
        run.isResumable = session != nil
        return run
    }

    @Test("A thread is every turn of one conversation, oldest first")
    func threadIsOrdered() {
        var state = QueueAutoRunState()
        let first = threadRun("Turn 1", session: "s1", offset: 0)
        state.record(first)
        state.record(threadRun("Turn 3", session: "s1", offset: 200))
        state.record(threadRun("Turn 2", session: "s1", offset: 100))

        let thread = state.thread(containing: first)
        #expect(thread.map(\.taskTitle) == ["Turn 1", "Turn 2", "Turn 3"])
    }

    @Test("Threads are grouped by session, not by task")
    func threadsDoNotMergeAcrossSessions() {
        // Running the same task twice starts two independent conversations.
        // Splicing them would show the model answering a question from a
        // conversation it never saw.
        let taskID = UUID()
        var state = QueueAutoRunState()
        let first = threadRun("First run", session: "s1", offset: 0, taskID: taskID)
        state.record(first)
        state.record(threadRun("Second run", session: "s2", offset: 100, taskID: taskID))

        #expect(state.thread(containing: first).map(\.taskTitle) == ["First run"])
    }

    @Test("A run with no session is a thread of one")
    func threadWithoutSession() {
        // Every run made before session persistence was enabled looks like this.
        var state = QueueAutoRunState()
        let orphan = threadRun("Old run", session: nil, offset: 0)
        state.record(orphan)
        state.record(threadRun("Unrelated", session: nil, offset: 100))

        let thread = state.thread(containing: orphan)
        #expect(thread.count == 1)
        #expect(thread.first?.id == orphan.id)
    }

    @Test("Runs made before persistence are not offered a reply")
    func oldRunsAreNotResumable() {
        // The CLI reports a session ID even when it is about to throw the
        // transcript away, so the ID alone is not evidence of anything.
        var run = threadRun("Old run", session: "s1", offset: 0)
        run.isResumable = false
        #expect(run.sessionID != nil)
        #expect(!run.isResumable)
    }

    // MARK: - Usage credits

    /// The percentage thresholds guard the plan allowance. This guards what
    /// happens *past* it, where spending stops being quota and starts being a
    /// charge — and it holds even if the reported percentages are wrong.
    @Test("Nothing runs while the account can be charged for usage credits")
    func extraUsageBlocksTheQueue() {
        #expect(skipReason(input(extraUsageEnabled: true)) == .extraUsageEnabled)
    }

    /// Silence is not consent. An unreported setting is the case where Tokenmax
    /// cannot tell whether a run would be billed, and "cannot tell" resolves to
    /// "do not spend" everywhere else in this file.
    @Test("An unreported credit setting refuses rather than assuming it is off")
    func unknownExtraUsageBlocksTheQueue() {
        #expect(skipReason(input(extraUsageEnabled: nil)) == .extraUsageUnknown)
    }

    @Test("Credits disabled on the account is not a reason to skip")
    func extraUsageDisabledRuns() {
        #expect(skipReason(input(extraUsageEnabled: false)) == nil)
    }

    /// The negative half: the guard must stay quiet when switched off, or the
    /// toggle is not a toggle.
    @Test("Switching the credit guard off lets both states through")
    func extraUsageGuardIsOptional() {
        let permissive = settings(skipWhenExtraUsage: false)
        #expect(skipReason(input(settings: permissive, extraUsageEnabled: true)) == nil)
        #expect(skipReason(input(settings: permissive, extraUsageEnabled: nil)) == nil)
    }

    /// Same default as the opener's, and for the same reason: credits enabled
    /// is a normal account state, and refusing on it alone disables the feature
    /// for everyone who has them. This guard shipped defaulting on and stopped
    /// the queue outright on the first such account — the quota thresholds
    /// already keep a run away from the allowance, so it refused runs that
    /// could never have been charged.
    @Test("The credit guard is off by default, like the opener's")
    func extraUsageGuardDefaultsOff() {
        #expect(!QueueAutoRunSettings().skipWhenExtraUsageEnabled)
        #expect(!SessionOpenerSettings().skipWhenExtraUsageEnabled)
    }

    /// The guard being off must not be a way past the numeric thresholds —
    /// those are what actually keep a run clear of the plan allowance.
    @Test("With the credit guard off the quota floors still refuse")
    func creditGuardOffStillRespectsQuotaFloors() {
        let permissive = settings(skipWhenExtraUsage: false)
        #expect(
            skipReason(input(settings: permissive, weeklyRemaining: 2, extraUsageEnabled: true))
                == .weeklyQuotaLow
        )
        #expect(
            skipReason(input(settings: permissive, session: session(remaining: 5), extraUsageEnabled: true))
                == .sessionQuotaLow
        )
    }

    /// Ordering matters: a user who is below their weekly threshold *and* has
    /// credits on should be told about the threshold, which is the one they set
    /// and the one they can act on.
    @Test("A low weekly quota is reported before the credit guard")
    func weeklyQuotaOutranksExtraUsage() {
        #expect(
            skipReason(input(weeklyRemaining: 2, extraUsageEnabled: true)) == .weeklyQuotaLow
        )
    }

    /// The mid-run watchdog is the net under the gate above, and it is on by
    /// default for the same reason: unbounded billing is worse than a task
    /// stopped early.
    @Test("A new task stops itself when the quota runs out")
    func quotaWatchdogDefaultsOn() {
        #expect(TaskExecutionPolicy().stopWhenQuotaExhausted)
    }

    // MARK: - Scheduled appointments

    @Test("A task dated for later waits rather than running early")
    func futureAppointmentWaits() {
        #expect(skipReason(input(tasks: [scheduled(minutesFromNow: 60)])) == .notYetScheduled)
    }

    /// The whole point: outside the lead window, which is where the ordinary
    /// schedule refuses, an appointment runs anyway.
    @Test("A due appointment runs outside the burn lead window")
    func dueAppointmentIgnoresLeadWindow() {
        // Four hours from a reset is far outside the 45-minute lead time.
        let far = session(resetInMinutes: 240)
        #expect(skipReason(input(session: far, tasks: [task()])) == .outsideLeadWindow)
        #expect(skipReason(input(session: far, tasks: [scheduled(minutesFromNow: -1)])) == nil)
    }

    /// The user confirmed this explicitly: an appointment on an afternoon they
    /// were not coding must still fire, and starting the task is what opens the
    /// window. Without this the feature is silently useless on exactly the days
    /// it was asked for.
    @Test("A due appointment runs when no session window is open at all")
    func dueAppointmentOpensItsOwnWindow() {
        #expect(skipReason(input(noSessionWindow: true, tasks: [task()])) == .noSessionWindow)
        #expect(skipReason(input(noSessionWindow: true, tasks: [scheduled(minutesFromNow: -1)])) == nil)
    }

    /// An appointment is not part of the opportunistic burn, so it is not
    /// rationed by the burn's per-window allowances — `RunTrigger.scheduled`
    /// keeps it out of the arithmetic on the other side too.
    @Test("A due appointment is not blocked by the per-window task allowance")
    func dueAppointmentIgnoresWindowBudgets() {
        var state = QueueAutoRunState()
        state.record(TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Already ran",
            windowID: QueueAutoRun.windowID(resetAt: now.addingTimeInterval(30 * 60)),
            trigger: .automatic,
            startedAt: now.addingTimeInterval(-600),
            model: "sonnet",
            workingDirectory: realDirectory
        ))

        #expect(skipReason(input(tasks: [task()], state: state)) == .maximumTasksReached)
        #expect(skipReason(input(tasks: [scheduled(minutesFromNow: -1)], state: state)) == nil)
    }

    /// A scheduled run must not consume the burn window's allowance either,
    /// or one appointment would silently cancel that evening's automatic task.
    @Test("A scheduled run does not spend the window's automatic allowance")
    func scheduledRunsDoNotCountAgainstTheWindow() {
        let window = QueueAutoRun.windowID(resetAt: now.addingTimeInterval(30 * 60))
        var state = QueueAutoRunState()
        state.record(TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Appointment",
            windowID: window,
            trigger: .scheduled,
            startedAt: now.addingTimeInterval(-600),
            model: "sonnet",
            workingDirectory: realDirectory
        ))

        #expect(state.automaticRuns(inWindow: window).isEmpty)
        #expect(state.totalRuntime(inWindow: window, now: now) == 0)
        #expect(skipReason(input(tasks: [task()], state: state)) == nil)
    }

    /// The negative half of every bypass above: an appointment overrides *when*
    /// to run and nothing else. Each of these would have been a way to spend
    /// past a guard the user set by simply dating a task.
    @Test("A due appointment is still refused by every quota and safety guard")
    func dueAppointmentRespectsEveryOtherGuard() {
        let due = scheduled(minutesFromNow: -1)

        #expect(skipReason(input(session: session(remaining: 5), tasks: [due])) == .sessionQuotaLow)
        #expect(skipReason(input(weeklyRemaining: 2, tasks: [due])) == .weeklyQuotaLow)
        #expect(skipReason(input(weeklyRemaining: nil, tasks: [due])) == .weeklyQuotaUnknown)
        #expect(skipReason(input(extraUsageEnabled: true, tasks: [due])) == .extraUsageEnabled)
        #expect(skipReason(input(extraUsageEnabled: nil, tasks: [due])) == .extraUsageUnknown)
        #expect(skipReason(input(isStale: true, tasks: [due])) == .dataStale)
        #expect(skipReason(input(tasks: [due], awaitingFreshUsage: true)) == .awaitingFreshUsage)
        #expect(skipReason(input(cliInstalled: false, tasks: [due])) == .cliNotInstalled)
        #expect(skipReason(input(tasks: [due], runInFlight: true)) == .runInFlight)
        #expect(skipReason(input(queueEnabled: false, tasks: [due])) == .queueDisabled)
        #expect(skipReason(input(settings: settings(enabled: false), tasks: [due])) == .disabled)
    }

    @Test("A due appointment still respects quiet hours")
    func dueAppointmentRespectsQuietHours() {
        var hours = QuietHours()
        hours.enabled = true
        hours.startMinutes = 0
        hours.endMinutes = 1439
        #expect(skipReason(input(quietHours: hours, tasks: [scheduled(minutesFromNow: -1)])) == .quietHours)
    }

    /// Dating a task is not the same as approving it for automation, and the
    /// two switches live in different places — so this is the mistake most
    /// likely to be made. The editor warns about it for the same reason.
    @Test("A dated task that is not approved for automation still does not run")
    func appointmentIsNotApproval() {
        var manual = scheduled(minutesFromNow: -1)
        manual.executionMode = .manual
        #expect(skipReason(input(tasks: [manual])) == .noApprovedTask)
    }

    @Test("A dated task without a runtime estimate still does not run")
    func appointmentStillNeedsAnEstimate() {
        let unsized = scheduled(minutesFromNow: -1, estimate: nil)
        #expect(
            QueueAutoRun.eligibility(for: unsized, resetAt: nil, settings: settings(), now: now)
                == .noRuntimeEstimate
        )
    }

    /// A Mac asleep at four o'clock must not wake at midnight and start work
    /// against a project that has moved on.
    @Test("An appointment missed by more than the grace period expires")
    func missedAppointmentExpires() {
        var lenient = settings()
        lenient.scheduleGraceMinutes = 120

        let missed = scheduled(minutesFromNow: -180)
        #expect(QueueAutoRun.isExpired(missed, settings: lenient, now: now))
        #expect(!QueueAutoRun.isDue(missed, settings: lenient, now: now))
        // Named as what it is. "Not enough time before the reset" would send
        // the user to the wrong setting entirely.
        #expect(skipReason(input(settings: lenient, tasks: [missed])) == .scheduleExpired)

        // Inside the grace period it is still honoured — a lid closed for an
        // hour is the common case, and the task is usually still wanted.
        let late = scheduled(minutesFromNow: -60)
        #expect(!QueueAutoRun.isExpired(late, settings: lenient, now: now))
        #expect(QueueAutoRun.isDue(late, settings: lenient, now: now))
    }

    /// At the moment an appointment comes round, the single available slot must
    /// go to the task that was dated, not to whatever sorts highest.
    @Test("A due appointment outranks queue order")
    func dueAppointmentWinsTheSlot() {
        let urgent = task(title: "Urgent", sortIndex: -10)
        let dated = task(title: "Dated", sortIndex: 10, scheduledStart: now.addingTimeInterval(-60))

        let decision = QueueAutoRun.decide(input(tasks: [urgent, dated]))
        #expect(decision.taskID == dated.id)
    }

    /// A waiting appointment is a normal state, so it must not be reported as
    /// the queue running out of time — and it must not mask a second task that
    /// genuinely will not fit.
    @Test("Waiting for an appointment is reported as waiting, not as a shortage")
    func waitingIsNotAShortage() {
        #expect(skipReason(input(tasks: [scheduled(minutesFromNow: 120)])) == .notYetScheduled)

        // A task that will not fit before the reset alongside a dated one still
        // reports the shortage, which is the actionable half.
        let tooLong = task(title: "Long", runtimeCap: 60)
        #expect(
            skipReason(input(tasks: [scheduled(minutesFromNow: 120), tooLong])) == .insufficientTime
        )
    }

    /// Not merely a waiting state: the mode is the master switch, and an
    /// appointment must not be a way around preview mode.
    @Test("A due appointment obeys the automation mode")
    func dueAppointmentObeysMode() {
        let due = [scheduled(minutesFromNow: -1)]
        #expect(QueueAutoRun.decide(input(settings: settings(mode: .previewOnly), tasks: due)).taskID != nil)
        if case .preview = QueueAutoRun.decide(input(settings: settings(mode: .previewOnly), tasks: due)) {
        } else {
            Issue.record("preview mode must not start a scheduled task")
        }
        if case .ask = QueueAutoRun.decide(input(settings: settings(mode: .askBeforeRunning), tasks: due)) {
        } else {
            Issue.record("ask mode must not start a scheduled task by itself")
        }
    }

    /// Two appointments for the same task at different times are different
    /// runs, and a run with no session window still needs a key of its own.
    @Test("A scheduled run gets a window key even with no session open")
    func scheduledWindowIDIsStableAndUnique() {
        let first = scheduled(minutesFromNow: -1)
        var second = first
        second.scheduledStart = now.addingTimeInterval(3600)

        #expect(QueueAutoRun.scheduledWindowID(for: first) == QueueAutoRun.scheduledWindowID(for: first))
        #expect(QueueAutoRun.scheduledWindowID(for: first) != QueueAutoRun.scheduledWindowID(for: second))
        #expect(QueueAutoRun.scheduledWindowID(for: first).hasPrefix("scheduled-"))
    }

    /// The burn window must not treat a dated task as ordinary queue fodder.
    /// Giving a task a time is also a statement about when it may *not* run,
    /// and the burn schedule is otherwise free to pick anything approved.
    @Test("A task dated for later is never picked up by the burn window")
    func futureDatedTaskStaysOutOfTheBurnWindow() {
        // Everything the burn path wants: inside the lead time, quota fine,
        // room in the per-window budget. The only task is dated for later.
        let later = scheduled(minutesFromNow: 240)
        let decision = QueueAutoRun.decide(input(tasks: [later]))
        #expect(decision.taskID == nil, "burn window picked a task dated for later: \(decision)")
        #expect(decision.skipReason == .notYetScheduled)
    }

    /// The dated task must be passed over rather than blocking the queue: an
    /// appointment for Friday should not stop today's ordinary burn.
    @Test("A dated task is skipped over, not in front of, an undated one")
    func datedTaskDoesNotBlockTheQueue() {
        let later = scheduled(minutesFromNow: 240)
        let plain = task(title: "Plain", sortIndex: 10)
        let decision = QueueAutoRun.decide(input(tasks: [later, plain]))
        #expect(decision.taskID == plain.id)
    }

    // MARK: - The weekly window as the window to burn

    /// Codex on a Plus plan reports a single 7-day limit and no 5-hour one. Its
    /// queue would otherwise never run: there is no session window about to
    /// expire, and the burn schedule has nothing else to spend against.
    @Test("A provider with only a weekly window burns that window")
    func weeklyWindowStandsInForAMissingSessionWindow() {
        let decision = QueueAutoRun.decide(input(
            noSessionWindow: true,
            weeklyResetInMinutes: 30,
            burnFallsBackToWeekly: true,
            providerID: TokenmaxProvider.codex.rawValue
        ))
        #expect(decision.taskID != nil, "expected a run, got \(decision)")
        #expect(decision.windowID?.hasPrefix("autorun-codex-") == true)
    }

    /// The other half of the case above, and the one that matters more: Claude
    /// reports both windows, so it must never start spending a seven-day
    /// allowance because the five-hour one happens to be absent.
    @Test("Without the fallback a missing session window still refuses")
    func weeklyWindowIsNotBurntWithoutTheFallback() {
        let decision = QueueAutoRun.decide(input(
            noSessionWindow: true,
            weeklyResetInMinutes: 30,
            burnFallsBackToWeekly: false
        ))
        #expect(decision.skipReason == .noSessionWindow)
    }

    /// The session window expires soonest, so it is the one worth spending. The
    /// fallback is a stand-in, never a second schedule.
    @Test("The session window wins when the provider reports both")
    func sessionWindowIsPreferredOverWeekly() {
        let sessionReset = now.addingTimeInterval(30 * 60)
        let decision = QueueAutoRun.decide(input(
            session: session(resetInMinutes: 30),
            weeklyResetInMinutes: 20,
            burnFallsBackToWeekly: true,
            providerID: TokenmaxProvider.codex.rawValue
        ))
        #expect(decision.windowID == QueueAutoRun.windowID(
            resetAt: sessionReset,
            providerID: TokenmaxProvider.codex.rawValue
        ))
    }

    /// One allowance must not be judged against two thresholds. The session
    /// floor is written for a five-hour window; applied to the weekly window it
    /// would refuse at 25% where the user asked to be stopped at 10%.
    @Test("The session floor is not applied to a weekly burn window")
    func sessionFloorDoesNotGovernAWeeklyBurnWindow() {
        // Below the 25% session floor, comfortably above the 10% weekly one.
        let decision = QueueAutoRun.decide(input(
            noSessionWindow: true,
            weeklyRemaining: 20,
            weeklyResetInMinutes: 30,
            burnFallsBackToWeekly: true,
            providerID: TokenmaxProvider.codex.rawValue
        ))
        #expect(decision.taskID != nil, "expected a run, got \(decision)")
    }

    /// The weekly floor is the one that governs it, and it still refuses.
    @Test("The weekly floor still holds for a weekly burn window")
    func weeklyFloorStillGovernsAWeeklyBurnWindow() {
        let decision = QueueAutoRun.decide(input(
            noSessionWindow: true,
            weeklyRemaining: 5,
            weeklyResetInMinutes: 30,
            burnFallsBackToWeekly: true,
            providerID: TokenmaxProvider.codex.rawValue
        ))
        #expect(decision.skipReason == .weeklyQuotaLow)
    }

    /// The lead window is not skipped for the stand-in. A seven-day window that
    /// resets on Friday must not run a task on Monday.
    @Test("A weekly burn window outside the lead time refuses")
    func weeklyBurnWindowRespectsTheLeadTime() {
        let decision = QueueAutoRun.decide(input(
            noSessionWindow: true,
            weeklyResetInMinutes: 600,
            burnFallsBackToWeekly: true,
            providerID: TokenmaxProvider.codex.rawValue
        ))
        #expect(decision.skipReason == .outsideLeadWindow)
    }

    /// A window that has not started yet is not a window to burn, whichever
    /// window it is.
    @Test("A weekly window that has not started is not burnt")
    func unstartedWeeklyWindowIsNotBurnt() {
        let unstarted = UsageWindow(
            id: "codex.weekly",
            kind: .weekly,
            label: "Weekly",
            usedPercent: 0,
            resetAt: nil,
            observedAt: now,
            source: .codexAppServer,
            confidence: .authoritative
        )
        let decision = QueueAutoRun.decide(QueueAutoRun.Input(
            providerID: TokenmaxProvider.codex.rawValue,
            settings: settings(),
            sessionWindow: nil,
            weeklyWindow: unstarted,
            burnFallsBackToWeekly: true,
            tasks: [task()],
            now: now
        ))
        #expect(decision.skipReason == .noSessionWindow)
    }
}
