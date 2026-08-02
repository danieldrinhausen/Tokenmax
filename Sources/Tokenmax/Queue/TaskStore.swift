import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TokenmaxTask] = []

    init() {
        let file = JSONStore.load(TaskFile.self, from: FileLocations.tasksFile) ?? TaskFile()
        tasks = file.tasks
    }

    // MARK: - Queries

    /// Ready tasks in the order they should be worked: manual order first,
    /// then priority, then age.
    var readyTasks: [TokenmaxTask] {
        tasks
            .filter { $0.status == .ready }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                if lhs.priority.sortWeight != rhs.priority.sortWeight {
                    return lhs.priority.sortWeight > rhs.priority.sortWeight
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func tasks(withStatus status: TaskStatus) -> [TokenmaxTask] {
        tasks.filter { $0.status == status }
    }

    var readyCount: Int { count(of: .ready) }
    var runningCount: Int { count(of: .running) }
    var completedCount: Int { count(of: .completed) }
    var needsAttentionCount: Int { count(of: .needsAttention) }

    private func count(of status: TaskStatus) -> Int {
        tasks.reduce(into: 0) { $0 += ($1.status == status ? 1 : 0) }
    }

    // MARK: - Mutations

    func add(_ task: TokenmaxTask) {
        var task = task
        task.sortIndex = (tasks.map(\.sortIndex).min() ?? 0) - 1
        tasks.append(task)
        persist()
    }

    func update(_ task: TokenmaxTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        updated.updatedAt = Date()
        tasks[index] = updated
        persist()
    }

    func delete(_ task: TokenmaxTask) {
        tasks.removeAll { $0.id == task.id }
        persist()
    }

    func duplicate(_ task: TokenmaxTask) {
        var copy = task
        copy.id = UUID()
        copy.title = "\(task.title) copy"
        copy.status = .ready
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.startedAt = nil
        copy.completedAt = nil
        copy.errorMessage = nil
        add(copy)
    }

    func moveToTop(_ task: TokenmaxTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].sortIndex = (tasks.map(\.sortIndex).min() ?? 0) - 1
        tasks[index].updatedAt = Date()
        persist()
    }

    /// Applies a drag reorder of the ready queue.
    ///
    /// Only ready tasks are renumbered — a completed task's `sortIndex` is
    /// meaningless to the runner, and rewriting it would silently reshuffle
    /// history. The arithmetic itself lives in `QueueListModel.reordered`.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let updates = QueueListModel.reordered(readyTasks, fromOffsets: offsets, toOffset: destination)
        guard !updates.isEmpty else { return }

        let now = Date()
        for (id, sortIndex) in updates {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { continue }
            tasks[index].sortIndex = sortIndex
            tasks[index].updatedAt = now
        }

        persist()
    }

    func setStatus(_ status: TaskStatus, for task: TokenmaxTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()

        switch status {
        case .running:
            tasks[index].startedAt = Date()
            tasks[index].completedAt = nil
        case .completed:
            tasks[index].completedAt = Date()
            tasks[index].errorMessage = nil
        case .ready:
            // Retrying after a failure clears the old error.
            tasks[index].errorMessage = nil
            tasks[index].startedAt = nil
            tasks[index].completedAt = nil
        case .needsAttention, .archived:
            break
        }

        persist()
    }

    func markNeedsAttention(_ task: TokenmaxTask, message: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].status = .needsAttention
        tasks[index].errorMessage = message
        tasks[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        JSONStore.save(TaskFile(version: 1, tasks: tasks), to: FileLocations.tasksFile)
    }
}
