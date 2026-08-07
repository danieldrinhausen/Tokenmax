import Foundation

/// How far Tokenmax is allowed to go on its own when it finds an eligible task.
///
/// The three cases are a deliberate ramp rather than a preference: `previewOnly`
/// exercises every guard in `QueueAutoRun.decide` without spending anything, so
/// the decision logic can be watched for days before it is trusted with real
/// quota and real file changes.
enum QueueAutoRunMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Evaluate and report. Never launches Claude.
    case previewOnly
    /// Notify, and start only if the user says so.
    case askBeforeRunning
    /// Start after the preflight countdown, with no further confirmation.
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .previewOnly: "Preview only"
        case .askBeforeRunning: "Ask before running"
        case .automatic: "Automatic"
        }
    }

    var explanation: String {
        switch self {
        case .previewOnly:
            "Tokenmax works out which task it would run and shows you, but never starts anything."
        case .askBeforeRunning:
            "Tokenmax notifies you when a task becomes eligible and waits for you to start it."
        case .automatic:
            "Tokenmax starts the task itself after a short countdown you can cancel."
        }
    }
}

/// What Tokenmax may do with a running task when the session window resets
/// underneath it.
///
/// The default is deliberately *not* to stop: a coding task killed halfway
/// through an edit leaves the repository in a worse state than never having run
/// it, and the quota it was going to spend is already spent.
enum ResetBoundaryBehavior: String, Codable, Sendable, CaseIterable, Identifiable {
    case letTaskFinish
    case stopAtDeadline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letTaskFinish: "Let the task finish"
        case .stopAtDeadline: "Stop the task at the safety deadline"
        }
    }
}

/// The opt-in queue auto-runner: spend quota that is about to expire by running
/// a task the user has explicitly approved for automation.
///
/// Deliberately *not* derived from `sessionReminder`, which `BurnOpportunity`
/// uses. A reminder that fires too early is an annoyance; a task that starts too
/// early edits files. Changing a notification lead time from 30 to 60 minutes
/// must never change when code runs, so the two carry separate lead times even
/// though they usually want similar values.
struct QueueAutoRunSettings: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var mode: QueueAutoRunMode = .previewOnly

    /// Start considering tasks this many minutes before the session resets.
    var leadTimeMinutes: Int = 45

    /// Never start a task below this remaining session quota.
    var minimumSessionRemainingPercent: Double = 25

    /// Never start a task below this remaining weekly quota. The five-hour and
    /// weekly allowances share one budget, so a run is never free of the weekly.
    var minimumWeeklyRemainingPercent: Double = 10

    /// Refuse to start a task within this long of the reset, so a run has room
    /// to finish inside the window that paid for it.
    var safetyMarginMinutes: Int = 10

    /// How many tasks Tokenmax may start by itself in one session window.
    /// One, until there is real data about how long tasks actually take.
    var maximumTasksPerWindow: Int = 1

    /// Total automatic runtime allowed per session window, across all tasks.
    var maximumRuntimeMinutes: Int = 30

    /// Grace period between deciding to run and actually spawning, so an
    /// unintended run can be stopped without a confirmation dialog every time.
    var startDelaySeconds: Int = 30

    /// Only tasks whose `executionMode` is `.automatic` may be started
    /// automatically. Switching this off is not offered as a way to run
    /// unmarked tasks — it exists so the guard is visible in Settings.
    var onlyRunApprovedTasks: Bool = true

    /// Stop the automatic queue after the first failure rather than moving on.
    /// A failing task usually means the next one fails the same way.
    var pauseAfterFailure: Bool = true

    /// Treat a stale usage reading as a hard stop. On by default: every quota
    /// guard below is meaningless against numbers we do not trust.
    var requireFreshUsageData: Bool = true

    var resetBoundaryBehavior: ResetBoundaryBehavior = .letTaskFinish

    var respectQuietHours: Bool = true

    /// Refuse to start anything while the account can charge for extra usage.
    ///
    /// On by default, where `SessionOpenerSettings.skipWhenExtraUsageEnabled`
    /// is off — the two features sit at opposite ends of a window. The opener
    /// only ever runs into a window that has just reset, with the weekly
    /// allowance above its threshold, so it cannot reach a charge and a blanket
    /// refusal there only disabled the feature for anyone who has credits on.
    /// The auto-runner is the inverse by design: it exists to spend the tail of
    /// a window, which is exactly where the plan allowance runs out and paid
    /// credits take over. Past that point the CLI does not stop — it keeps
    /// going and bills.
    var skipWhenExtraUsageEnabled: Bool = true

    var notifyOnStart: Bool = true
    var notifyOnCompletion: Bool = true
    /// Not offered as a toggle in the UI. A silently paused queue is the state
    /// most likely to be mistaken for a broken app.
    var notifyOnFailure: Bool = true

    static let leadTimeOptions = [15, 30, 45, 60, 90, 120]
    static let sessionThresholdOptions = [10.0, 25.0, 40.0, 50.0]
    static let weeklyThresholdOptions = [5.0, 10.0, 20.0, 30.0]
    static let safetyMarginOptions = [5, 10, 15, 20, 30]
    static let maximumTasksOptions = [1, 2, 3, 5]
    static let maximumRuntimeOptions = [15, 30, 45, 60, 90]
    static let startDelayOptions = [10, 30, 60, 120]

    init() {}

    /// Lenient for the same reason as `AppSettings.init(from:)` — see there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = QueueAutoRunSettings()

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        // `try?` so a mode hand-edited into something undecodable costs the user
        // that one setting rather than re-enabling automation at its default.
        mode = (try? container.decodeIfPresent(QueueAutoRunMode.self, forKey: .mode)) ?? d.mode
        leadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .leadTimeMinutes) ?? d.leadTimeMinutes
        minimumSessionRemainingPercent = try container.decodeIfPresent(
            Double.self, forKey: .minimumSessionRemainingPercent
        ) ?? d.minimumSessionRemainingPercent
        minimumWeeklyRemainingPercent = try container.decodeIfPresent(
            Double.self, forKey: .minimumWeeklyRemainingPercent
        ) ?? d.minimumWeeklyRemainingPercent
        safetyMarginMinutes = try container.decodeIfPresent(Int.self, forKey: .safetyMarginMinutes)
            ?? d.safetyMarginMinutes
        maximumTasksPerWindow = try container.decodeIfPresent(Int.self, forKey: .maximumTasksPerWindow)
            ?? d.maximumTasksPerWindow
        maximumRuntimeMinutes = try container.decodeIfPresent(Int.self, forKey: .maximumRuntimeMinutes)
            ?? d.maximumRuntimeMinutes
        startDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .startDelaySeconds) ?? d.startDelaySeconds
        onlyRunApprovedTasks = try container.decodeIfPresent(Bool.self, forKey: .onlyRunApprovedTasks)
            ?? d.onlyRunApprovedTasks
        pauseAfterFailure = try container.decodeIfPresent(Bool.self, forKey: .pauseAfterFailure) ?? d.pauseAfterFailure
        requireFreshUsageData = try container.decodeIfPresent(Bool.self, forKey: .requireFreshUsageData)
            ?? d.requireFreshUsageData
        resetBoundaryBehavior = (try? container.decodeIfPresent(
            ResetBoundaryBehavior.self, forKey: .resetBoundaryBehavior
        )) ?? d.resetBoundaryBehavior
        respectQuietHours = try container.decodeIfPresent(Bool.self, forKey: .respectQuietHours) ?? d.respectQuietHours
        skipWhenExtraUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .skipWhenExtraUsageEnabled)
            ?? d.skipWhenExtraUsageEnabled
        notifyOnStart = try container.decodeIfPresent(Bool.self, forKey: .notifyOnStart) ?? d.notifyOnStart
        notifyOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion)
            ?? d.notifyOnCompletion
        notifyOnFailure = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? d.notifyOnFailure
    }
}

/// What one task is allowed to do when Tokenmax runs it.
///
/// There is deliberately no `allowed` flag here: `TokenmaxTask.executionMode` is
/// the single permission gate. Two switches for one decision drift apart, and
/// when they disagree neither the code nor the user can say which wins.
struct TaskExecutionPolicy: Codable, Sendable, Equatable {
    /// Hard ceiling. The runner terminates the process at this point, which is
    /// why `QueueAutoRun` budgets the time before a reset against *this* rather
    /// than the task's estimate — this is the real worst case.
    var maximumRuntimeMinutes: Int = 15

    /// Passed to the CLI as `--max-budget-usd`. Claude enforces it itself, which
    /// makes it the one limit that holds even if Tokenmax is killed mid-run.
    var maximumBudgetUSD: Double = 0.50

    /// An alias (`opus`, `sonnet`, `fable`) or a full model id
    /// (`claude-opus-5`). Deliberately a free-form `String`: an alias resolves
    /// to the newest model of that family at run time, so a new release needs no
    /// change here, and a full id typed into the editor is stored as-is.
    var model: String = "sonnet"

    /// Passed to the CLI as `--effort`. nil leaves the flag off entirely, which
    /// is what preserves the behaviour of every task written before this
    /// existed — the CLI picks its own default.
    var effort: String?

    /// Grants `Edit` and `Write`. Off means a read-only run: the task can
    /// investigate and report but cannot touch the working tree.
    var allowFileChanges: Bool = true

    /// Grants `Bash`. Separate from file changes because a prompt can lead
    /// Claude to invoke arbitrary project commands — build scripts, test
    /// runners, anything on the PATH.
    var allowShellCommands: Bool = false

    /// Terminate the run the moment either quota window reads empty.
    ///
    /// The start gates cannot cover this: a run approved at 30% remaining can
    /// still exhaust the window while it works, and the CLI does not stop there
    /// — it spends paid credits. This is the only guard that acts *during* a
    /// run, and it is a blunt one. Usage readings are 180s apart at best
    /// (`ClaudeOAuthUsageClient.minimumRequestInterval`), so it reacts late, and
    /// a task killed halfway through an edit leaves the project worse than
    /// never having run — the same reasoning that makes `letTaskFinish` the
    /// default at a reset boundary. On by default because unbounded billing is
    /// the worse of the two outcomes, off per task when the work matters more.
    var stopWhenQuotaExhausted: Bool = true

    /// Aliases rather than pinned ids on purpose: `--model opus` resolves to the
    /// newest Opus at run time, so this list does not go stale when a model
    /// version ships. The editor's "Other…" field covers pinning a full id.
    static let modelOptions = ["haiku", "sonnet", "opus", "fable"]
    static let runtimeOptions = [5, 10, 15, 30, 45, 60]

    /// Common values, not a ceiling. Deliberately open-ended at the top because
    /// the amount worth spending depends entirely on the plan: burning a week's
    /// remaining Max allowance on a Friday afternoon is a different order of
    /// magnitude from a ten-minute chore. Anything not in this list is typed
    /// into the editor's "Other…" field and stored verbatim.
    static let budgetOptions = [0.10, 0.25, 0.50, 1.00, 2.00, 5.00, 10.00, 25.00, 50.00, 100.00]

    /// Sentinel for the editor's "Other…" row. Negative because no real budget
    /// can be, so it can never collide with a stored value — and `init(from:)`
    /// rejects it on the way back in if it ever reaches disk.
    static let customBudgetTag = -1.0

    /// The levels `claude --effort` accepts.
    static let effortOptions = ["low", "medium", "high", "xhigh", "max"]

    static func modelDisplayName(_ raw: String) -> String {
        switch raw {
        case "haiku": "Haiku"
        case "sonnet": "Sonnet"
        case "opus": "Opus"
        case "fable": "Fable"
        // A full model id, or an alias added after this build shipped. Shown as
        // typed rather than mangled by `capitalized`.
        default: raw
        }
    }

    static func effortDisplayName(_ raw: String?) -> String {
        switch raw {
        case nil, "": "Default"
        case "xhigh": "Extra high"
        case let value?: value.capitalized
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = TaskExecutionPolicy()
        maximumRuntimeMinutes = try container.decodeIfPresent(Int.self, forKey: .maximumRuntimeMinutes)
            ?? d.maximumRuntimeMinutes
        // A zero or negative budget is not "spend nothing" — the CLI rejects the
        // flag outright, so the run would fail rather than be cheap. It is also
        // the shape `customBudgetTag` takes, which must never survive a round
        // trip through disk.
        let budget = try container.decodeIfPresent(Double.self, forKey: .maximumBudgetUSD) ?? d.maximumBudgetUSD
        maximumBudgetUSD = budget > 0 ? budget : d.maximumBudgetUSD
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? d.model
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        allowFileChanges = try container.decodeIfPresent(Bool.self, forKey: .allowFileChanges) ?? d.allowFileChanges
        allowShellCommands = try container.decodeIfPresent(Bool.self, forKey: .allowShellCommands)
            ?? d.allowShellCommands
        stopWhenQuotaExhausted = try container.decodeIfPresent(Bool.self, forKey: .stopWhenQuotaExhausted)
            ?? d.stopWhenQuotaExhausted
    }

    /// The tools the runner will actually allow, in the order the CLI expects.
    ///
    /// Every file tool carries the `(**)` path specifier, which confines it to
    /// the task's working directory. This is **not** cosmetic: verified against
    /// the CLI, a bare `Write` on the allowlist is auto-approved for *any* path
    /// on the machine — a task pointed at one project will happily write to
    /// `/tmp`, or anywhere else the user can. `Write(**)` denies exactly that
    /// while leaving in-project edits untouched.
    ///
    /// Read-only access is unconditional — a task that cannot read its own
    /// project cannot do anything useful — but it is scoped for the same reason:
    /// an unattended run has no business reading credentials elsewhere on disk.
    var allowedTools: [String] {
        var tools = ["Read(**)", "Glob(**)", "Grep(**)"]
        if allowFileChanges { tools += ["Edit(**)", "Write(**)"] }
        // Deliberately unscoped, because it cannot be scoped meaningfully: a
        // shell can write anywhere regardless of what the file tools allow.
        // That is exactly why it is a separate opt-in, and why the disclosure
        // says so rather than implying the working directory still contains it.
        if allowShellCommands { tools.append("Bash") }
        return tools
    }

    /// The disclosure shown in the task editor, in the terms the user cares
    /// about rather than tool names.
    ///
    /// The wording is load-bearing. Shell access removes the working-directory
    /// confinement that the file tools otherwise enforce, so with it on the
    /// panel has to stop promising a boundary that is no longer there.
    var capabilitySummary: [(label: String, granted: Bool)] {
        [
            ("Read files in the working directory", true),
            ("Edit files in the working directory", allowFileChanges),
            ("Run shell commands — these can reach the whole machine", allowShellCommands),
            ("Use MCP tools", false),
        ]
    }

    /// Shown under the disclosure when the confinement no longer holds.
    var escapesWorkingDirectory: Bool { allowShellCommands }
}
