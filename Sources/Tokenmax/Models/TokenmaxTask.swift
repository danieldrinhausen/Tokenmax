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

    var estimatedMinutes: Int?

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
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
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
