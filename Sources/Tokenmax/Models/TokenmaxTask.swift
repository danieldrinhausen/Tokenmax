import Foundation

enum TaskPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case low, medium, high, urgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }

    /// Higher sorts first.
    var sortWeight: Int {
        switch self {
        case .urgent: 3
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }
}

enum TaskStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case ready
    case running
    case completed
    case needsAttention
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .running: "Running"
        case .completed: "Completed"
        case .needsAttention: "Needs Attention"
        case .archived: "Archived"
        }
    }
}

enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    case manual
    case askBeforeRunning
    case approvedForSession
    case automatic
}

struct TokenmaxTask: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = .init()

    var title: String
    var prompt: String

    var providerID: String = ClaudeCodeProvider.providerID
    var projectName: String?
    var workingDirectory: String?

    var priority: TaskPriority = .medium
    var status: TaskStatus = .ready
    var executionMode: ExecutionMode = .manual

    /// What this task is allowed to do when Tokenmax runs it. Independent of
    /// `executionMode`, which decides *whether* it may run at all.
    var autoRun: TaskExecutionPolicy = .init()
    /// Stored separately rather than overloading Claude's allowlisted-tools
    /// policy. Existing tasks decode exactly as Claude tasks.
    var codex: CodexExecutionPolicy = .init()

    var estimatedMinutes: Int?

    /// A one-off appointment: run this task at this moment, rather than
    /// whenever the session next happens to be near its reset.
    ///
    /// The burn-window schedule answers "spend what is about to expire", which
    /// is the wrong question for "I am away on Friday afternoon, use the week's
    /// leftover allowance then". Only the *timing* is overridden — every quota,
    /// account and safety gate still applies, so an appointment can spend no
    /// more than the same task would have spent unattended.
    ///
    /// Cleared when the run launches rather than when it finishes: a task that
    /// ends in `needsAttention` and is put back to `ready` must not fire again
    /// on a date that has long passed.
    var scheduledStart: Date?

    var createdAt: Date = .init()
    var updatedAt: Date = .init()
    var startedAt: Date?
    var completedAt: Date?

    /// Manual ordering. Lower sorts first; "Move to top" rewrites this.
    var sortIndex: Double = 0

    var outputFile: String?
    var errorMessage: String?

    init(
        id: UUID = .init(),
        title: String,
        prompt: String,
        providerID: String = ClaudeCodeProvider.providerID,
        projectName: String? = nil,
        workingDirectory: String? = nil,
        priority: TaskPriority = .medium,
        status: TaskStatus = .ready,
        executionMode: ExecutionMode = .manual,
        sortIndex: Double = 0
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.providerID = providerID
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.priority = priority
        self.status = status
        self.executionMode = executionMode
        self.sortIndex = sortIndex
    }

    /// Lenient for the same reason as `AppSettings`, but the stakes are higher:
    /// a strict decode failure here would discard the user's entire queue the
    /// first time a field was added. Only `title` and `prompt` are required,
    /// and even they degrade rather than throw.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled task"
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? ClaudeCodeProvider.providerID
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        priority = try container.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .medium
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .ready
        // `try?` so a retired execution mode degrades to "never run this
        // automatically" rather than throwing away the task.
        executionMode = (try? container.decodeIfPresent(ExecutionMode.self, forKey: .executionMode)) ?? .manual
        autoRun = try container.decodeIfPresent(TaskExecutionPolicy.self, forKey: .autoRun) ?? TaskExecutionPolicy()
        codex = try container.decodeIfPresent(CodexExecutionPolicy.self, forKey: .codex) ?? CodexExecutionPolicy()
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        scheduledStart = try container.decodeIfPresent(Date.self, forKey: .scheduledStart)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        sortIndex = try container.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        outputFile = try container.decodeIfPresent(String.self, forKey: .outputFile)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    var expandedWorkingDirectory: URL? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
    }

    var workingDirectoryExists: Bool {
        guard let url = expandedWorkingDirectory else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Whether the directory can actually be *opened*, not merely `stat`ed.
    ///
    /// These are different questions on macOS and the difference is not
    /// cosmetic. TCC gates reading Documents, Desktop, Downloads and iCloud
    /// Drive, but it does not gate `stat` — so a folder Tokenmax is forbidden to
    /// read still reports as existing. A task pointed at one looked perfectly
    /// eligible, spawned the CLI, and then blocked inside the CLI's first read
    /// until the runtime limit killed it: no output, no transcript, no
    /// explanation, and a paused queue.
    ///
    /// It has to open a **file**. Neither `open(O_DIRECTORY)` nor `readdir` will
    /// do, and both were tried: TCC gates reading the *contents* of Documents,
    /// Desktop and Downloads, not taking a handle on a directory or listing its
    /// names. Both of those succeed on a folder the app has no permission to
    /// read, so a probe built on either reports success while the real access is
    /// still ungranted — hiding the exact problem it exists to find, and letting
    /// the run proceed to the hang it was meant to prevent. Verified against the
    /// TCC database: the grant was written three minutes *after* a `readdir`
    /// probe had already reported success.
    ///
    /// `EPERM` is the denial that matters — that is TCC refusing. `EACCES` is
    /// ordinary Unix permissions on one file, which says nothing about the
    /// folder, so the scan moves on rather than condemning the whole directory.
    ///
    /// **This call is what raises the consent dialog, and it blocks until the
    /// dialog is answered.** Never call it on the main thread: see
    /// `WorkingDirectoryAccess`, which asks at launch while the user is present.
    var workingDirectoryReadable: Bool {
        guard let url = expandedWorkingDirectory else { return false }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: url.path) else { return false }

        // Bounded: proving the point needs one readable file, not a walk of a
        // large checkout.
        for name in names.prefix(64) {
            let path = url.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }

            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM { return false }
        }

        // Nothing to test against — an empty directory, or one holding only
        // subdirectories. Treated as readable rather than blocking a run over a
        // question that could not be asked.
        return true
    }

    var provider: TokenmaxProvider { TokenmaxProvider.from(identifier: providerID) ?? .claudeCode }

    var maximumRuntimeMinutes: Int {
        provider == .codex ? codex.maximumRuntimeMinutes : autoRun.maximumRuntimeMinutes
    }

    var selectedModel: String {
        provider == .codex ? codex.modelDisplayName : autoRun.model
    }

    /// The thinking grade this task runs at, or nil for whichever default the
    /// provider's own configuration supplies.
    var selectedEffort: String? {
        provider == .codex ? codex.reasoningEffort : autoRun.effort
    }
}

/// On-disk shape of `tokenmax.json`. Wrapping the array in a versioned envelope
/// leaves room to migrate without guessing at the old format.
struct TaskFile: Codable, Sendable {
    var version: Int = 1
    var tasks: [TokenmaxTask] = []

    init(version: Int = 1, tasks: [TokenmaxTask] = []) {
        self.version = version
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tasks = try container.decodeIfPresent([TokenmaxTask].self, forKey: .tasks) ?? []
    }
}
