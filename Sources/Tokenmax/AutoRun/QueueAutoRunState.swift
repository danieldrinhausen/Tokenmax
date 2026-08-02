import Foundation

/// What became of one task run.
enum TaskRunStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// Persisted before the process is spawned. Seeing this on disk at launch
    /// means Tokenmax died between recording the run and starting it.
    case starting
    case running
    case completed
    /// The CLI exited non-zero, or reported an error in its result envelope.
    case failed
    /// Killed at the policy's runtime ceiling.
    case timedOut
    /// Claude stopped itself at `--max-budget-usd`. Distinct from `failed`
    /// because the task did not go wrong — it ran out of the allowance the user
    /// gave it, and the partial work is usually still worth looking at.
    case budgetExceeded
    /// The user stopped it, at either the countdown or the run.
    case cancelled
    /// Found unfinished at launch. See `QueueAutoRunCoordinator.recoverInterruptedRuns`.
    case interrupted

    var isFinished: Bool {
        switch self {
        case .starting, .running: false
        default: true
        }
    }

    /// Whether this outcome should trip `pauseAfterFailure`.
    ///
    /// Cancelling is deliberately excluded: stopping one task by hand must not
    /// silently pause the whole queue, which is the opposite of what the user
    /// just asked for. `budgetExceeded` is excluded for the same reason — the
    /// limit did its job.
    var pausesQueue: Bool {
        switch self {
        case .failed, .timedOut, .interrupted: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .timedOut: "Timed out"
        case .budgetExceeded: "Budget reached"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

/// Why this run happened. Only `.automatic` counts against the per-window
/// limits — a manual test run must not consume the window's budget, or testing
/// the runner would disable the automation you are testing.
enum RunTrigger: String, Codable, Sendable, Equatable {
    case automatic
    case manual
}

/// One execution of one task.
///
/// Written *before* the process is spawned, for the same reason
/// `SessionOpenerAttempt` is: a crash between spawning and recording would
/// otherwise leave no trace of quota that was really spent.
struct TaskRunRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = .init()
    var taskID: UUID
    /// Copied rather than looked up, so a completion notification can still
    /// name the task after it has been deleted from the queue.
    var taskTitle: String

    /// Which session window this ran in. See `QueueAutoRun.windowID`.
    var windowID: String
    var trigger: RunTrigger

    var startedAt: Date
    var finishedAt: Date?

    var providerID: String
    var model: String
    var workingDirectory: String

    var status: TaskRunStatus
    var exitCode: Int32?
    var errorMessage: String?
    /// The model's final answer. Kept on the record as well as in the log
    /// because it is the one thing the user actually asked for, and the log is
    /// bounded — a long run can truncate away its own conclusion.
    var resultText: String?
    var costUSD: Double?
    /// Identifies the conversation, and doubles as the thread key: resuming
    /// without `--fork-session` keeps the original ID, so every turn of a
    /// follow-up thread carries the same one.
    var sessionID: String?

    /// Whether the conversation was saved to disk and can still be continued.
    ///
    /// Not derived from `sessionID != nil`: runs made before session
    /// persistence was switched on reported an ID for a transcript the CLI
    /// immediately discarded. Those decode as `false` and are never offered a
    /// reply, rather than failing at the point the user tries.
    var isResumable = false

    /// What the user sent to start this run, when it was not the task's own
    /// prompt — i.e. a follow-up. `nil` for the first turn of a thread, which
    /// is also how the thread view tells the two apart.
    var replyText: String?

    /// Relative to `FileLocations.runLogsDirectory`.
    var outputFile: String?

    /// Session quota remaining either side of the run. Percentages rather than
    /// whole snapshots: the two numbers are what the history is for, and a
    /// snapshot per run would grow the state file without being read.
    var sessionRemainingBefore: Double?
    var sessionRemainingAfter: Double?

    init(
        id: UUID = .init(),
        taskID: UUID,
        taskTitle: String,
        windowID: String,
        trigger: RunTrigger,
        startedAt: Date = Date(),
        providerID: String = ClaudeCodeProvider.providerID,
        model: String,
        workingDirectory: String,
        status: TaskRunStatus = .starting,
        sessionRemainingBefore: Double? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.windowID = windowID
        self.trigger = trigger
        self.startedAt = startedAt
        self.providerID = providerID
        self.model = model
        self.workingDirectory = workingDirectory
        self.status = status
        self.sessionRemainingBefore = sessionRemainingBefore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID) ?? UUID()
        taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle) ?? "Untitled task"
        windowID = try container.decodeIfPresent(String.self, forKey: .windowID) ?? ""
        trigger = (try? container.decodeIfPresent(RunTrigger.self, forKey: .trigger)) ?? .manual
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? ClaudeCodeProvider.providerID
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "sonnet"
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        // An unreadable status must not read as "finished and fine". Anything
        // we cannot classify is something the user should look at.
        status = (try? container.decodeIfPresent(TaskRunStatus.self, forKey: .status)) ?? .interrupted
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        resultText = try container.decodeIfPresent(String.self, forKey: .resultText)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        // Absent on every run written before session persistence existed, which
        // is exactly the set that must not offer a reply.
        isResumable = try container.decodeIfPresent(Bool.self, forKey: .isResumable) ?? false
        replyText = try container.decodeIfPresent(String.self, forKey: .replyText)
        outputFile = try container.decodeIfPresent(String.self, forKey: .outputFile)
        sessionRemainingBefore = try container.decodeIfPresent(Double.self, forKey: .sessionRemainingBefore)
        sessionRemainingAfter = try container.decodeIfPresent(Double.self, forKey: .sessionRemainingAfter)
    }

    /// How long the run took, or has been going.
    func duration(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    var logFileURL: URL? {
        guard outputFile != nil else { return nil }
        return FileLocations.runLogFile(runID: id)
    }
}

/// Persisted so a relaunch cannot lose the record of what was already run.
struct QueueAutoRunState: Codable, Sendable, Equatable {
    var runs: [TaskRunRecord] = []

    /// Windows in which the queue was paused by a failure. Cleared when the
    /// user resumes, so a single failure stops the rest of *this* window rather
    /// than the feature permanently.
    var pausedWindowIDs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = try container.decodeIfPresent([TaskRunRecord].self, forKey: .runs) ?? []
        pausedWindowIDs = try container.decodeIfPresent([String].self, forKey: .pausedWindowIDs) ?? []
    }

    // MARK: - Queries

    /// Runs Tokenmax started by itself in this window. Manual runs are excluded
    /// deliberately — see `RunTrigger`.
    func automaticRuns(inWindow windowID: String) -> [TaskRunRecord] {
        runs.filter { $0.windowID == windowID && $0.trigger == .automatic }
    }

    /// Total automatic runtime spent in this window. An unfinished run counts
    /// what it has used so far, so a long-running task cannot slip past the
    /// window's runtime cap by simply not having ended yet.
    func totalRuntime(inWindow windowID: String, now: Date = Date()) -> TimeInterval {
        automaticRuns(inWindow: windowID).reduce(0) { $0 + $1.duration(now: now) }
    }

    /// Runs that were never resolved — the app died with a task in flight.
    var unfinishedRuns: [TaskRunRecord] {
        runs.filter { !$0.status.isFinished }
    }

    var mostRecentRun: TaskRunRecord? {
        runs.max { $0.startedAt < $1.startedAt }
    }

    func run(id: UUID) -> TaskRunRecord? {
        runs.first { $0.id == id }
    }

    func mostRecentRun(forTask taskID: UUID) -> TaskRunRecord? {
        runs.filter { $0.taskID == taskID }.max { $0.startedAt < $1.startedAt }
    }

    /// Every turn of one conversation, oldest first.
    ///
    /// Grouped by session rather than by task: the same task run twice starts
    /// two independent conversations, and they must not be spliced into one
    /// thread. A run with no session ID is a thread of one.
    func thread(containing run: TaskRunRecord) -> [TaskRunRecord] {
        guard let sessionID = run.sessionID else { return [run] }
        return runs
            .filter { $0.sessionID == sessionID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func isPaused(_ windowID: String) -> Bool {
        pausedWindowIDs.contains(windowID)
    }

    // MARK: - Mutation

    mutating func record(_ run: TaskRunRecord) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        if runs.count > 40 {
            runs.removeFirst(runs.count - 40)
        }
    }

    mutating func pause(_ windowID: String) {
        guard !pausedWindowIDs.contains(windowID) else { return }
        pausedWindowIDs.append(windowID)
        if pausedWindowIDs.count > 40 {
            pausedWindowIDs.removeFirst(pausedWindowIDs.count - 40)
        }
    }

    mutating func resume(_ windowID: String) {
        pausedWindowIDs.removeAll { $0 == windowID }
    }
}
