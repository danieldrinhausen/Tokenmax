import Foundation

/// Which of the two bands a filter belongs to.
///
/// The split is the whole point of the queue's information architecture: active
/// work is what the window is for, history is what it keeps. Making it a
/// property of the filter rather than a layout decision means the navigation and
/// the empty states cannot disagree about where a filter lives.
enum QueueSection: String, CaseIterable, Identifiable, Sendable {
    case queue
    case history

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queue: "Queue"
        case .history: "History"
        }
    }
}

/// One band of the queue window.
///
/// Deliberately has no `all` case, unlike the 0.1 filter bar. "All" mixed a
/// running task in with four finished ones and answered none of the questions
/// the window exists to answer; the five explicit states replace it.
enum QueueFilter: String, CaseIterable, Identifiable, Sendable {
    case ready
    case running
    case needsAttention
    case completed
    case archived

    var id: String { rawValue }

    var status: TaskStatus {
        switch self {
        case .ready: .ready
        case .running: .running
        case .needsAttention: .needsAttention
        case .completed: .completed
        case .archived: .archived
        }
    }

    var section: QueueSection {
        switch self {
        case .ready, .running, .needsAttention: .queue
        case .completed, .archived: .history
        }
    }

    var displayName: String { status.displayName }

    /// A shorter label for the segmented control, which has to fit three
    /// segments across a 560pt window without truncating.
    var shortName: String {
        switch self {
        case .needsAttention: "Attention"
        default: displayName
        }
    }

    static func cases(in section: QueueSection) -> [QueueFilter] {
        allCases.filter { $0.section == section }
    }
}

/// Presentation order only. None of these change `sortIndex`, so none of them
/// change what the auto-runner picks up next — that always reads
/// `TaskStore.readyTasks`.
enum QueueSort: String, CaseIterable, Identifiable, Sendable {
    case queueOrder
    case priority
    case recentlyUpdated
    case recentlyCompleted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queueOrder: "Queue Order"
        case .priority: "Priority"
        case .recentlyUpdated: "Recently Updated"
        case .recentlyCompleted: "Recently Completed"
        }
    }

    /// Only manual order can be dragged. Reordering a list sorted by priority
    /// would either be discarded on the next redraw or silently rewrite the
    /// priority the user set — both worse than not offering the handle.
    var supportsManualReordering: Bool { self == .queueOrder }
}

/// What a card offers, and which of it is prominent.
///
/// Kept as data rather than as branches inside the card views so the rule "each
/// state has exactly one primary action" is a fact that can be asserted in a
/// test rather than a convention that drifts.
enum TaskAction: String, Identifiable, Sendable, CaseIterable {
    case runWithClaude
    case stop
    case viewResult
    case viewOutput
    case viewError
    case retry
    case restore
    case edit
    case copyPrompt
    case openInTerminal
    case markComplete
    case moveToTop
    case duplicate
    case archive
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runWithClaude: "Run with Provider"
        case .stop: "Stop"
        case .viewResult: "View Result"
        case .viewOutput: "View Output"
        case .viewError: "View Error"
        case .retry: "Retry"
        case .restore: "Restore"
        case .edit: "Edit"
        case .copyPrompt: "Copy Prompt"
        case .openInTerminal: "Open in Terminal"
        case .markComplete: "Mark Complete"
        case .moveToTop: "Move to Top"
        case .duplicate: "Duplicate"
        case .archive: "Archive"
        case .delete: "Delete"
        }
    }

    var isDestructive: Bool { self == .delete }
}

/// The three tiers of one card's actions.
struct TaskActionSet: Equatable, Sendable {
    var primary: TaskAction
    var secondary: [TaskAction]
    var overflow: [TaskAction]

    var all: [TaskAction] { [primary] + secondary + overflow }
}

/// The pure half of the queue window: filtering, searching, sorting, counting,
/// and deciding which actions a card offers.
///
/// Split out of `QueueView` for the same reason `QueueAutoRun` is split out of
/// its coordinator — none of it needs SwiftUI, and all of it is worth testing
/// directly rather than through a view.
enum QueueListModel {
    // MARK: - Counts

    static func counts(_ tasks: [TokenmaxTask]) -> [TaskStatus: Int] {
        tasks.reduce(into: [:]) { counts, task in
            counts[task.status, default: 0] += 1
        }
    }

    static func count(_ tasks: [TokenmaxTask], _ filter: QueueFilter) -> Int {
        counts(tasks)[filter.status] ?? 0
    }

    // MARK: - Search

    /// Matches title, prompt, project, and working directory.
    ///
    /// Case- and diacritic-insensitive so searching "uberproject" finds
    /// "Überproject", and the raw stored path is searched rather than the
    /// abbreviated one shown on the card — a user typing part of a path they can
    /// see should find it, and a user typing the full path should too.
    static func matches(_ task: TokenmaxTask, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }

        let haystacks = [
            task.title,
            task.prompt,
            task.projectName ?? "",
            task.workingDirectory ?? "",
            // So "~/Documents" and "/Users/me/Documents" both find the same task.
            task.expandedWorkingDirectory?.path ?? "",
        ]

        return haystacks.contains { field in
            field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - Visible tasks

    /// The tasks a given filter, query, and sort should show.
    ///
    /// Presentation only: it never writes, and the order it returns has no
    /// bearing on which task runs next. `.queueOrder` reproduces
    /// `TaskStore.readyTasks` exactly so that what the user sees at the top of
    /// the Ready list is what "Run Next" will pick.
    static func visible(
        tasks: [TokenmaxTask],
        filter: QueueFilter,
        query: String = "",
        sort: QueueSort = .queueOrder
    ) -> [TokenmaxTask] {
        let matching = tasks
            .filter { $0.status == filter.status }
            .filter { matches($0, query: query) }

        return sorted(matching, by: sort)
    }

    static func sorted(_ tasks: [TokenmaxTask], by sort: QueueSort) -> [TokenmaxTask] {
        switch sort {
        case .queueOrder:
            tasks.sorted(by: queueOrder)
        case .priority:
            tasks.sorted { lhs, rhs in
                if lhs.priority.sortWeight != rhs.priority.sortWeight {
                    return lhs.priority.sortWeight > rhs.priority.sortWeight
                }
                return queueOrder(lhs, rhs)
            }
        case .recentlyUpdated:
            tasks.sorted { $0.updatedAt > $1.updatedAt }
        case .recentlyCompleted:
            // A task with no completion date has not finished, so it sorts after
            // everything that has rather than to an arbitrary end of the list.
            tasks.sorted { lhs, rhs in
                switch (lhs.completedAt, rhs.completedAt) {
                case let (l?, r?): l > r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): lhs.updatedAt > rhs.updatedAt
                }
            }
        }
    }

    /// The same ordering `TaskStore.readyTasks` applies: manual order, then
    /// priority, then age. Duplicated here rather than called through the store
    /// because this half has to stay pure and testable without an actor.
    private static func queueOrder(_ lhs: TokenmaxTask, _ rhs: TokenmaxTask) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.priority.sortWeight != rhs.priority.sortWeight {
            return lhs.priority.sortWeight > rhs.priority.sortWeight
        }
        return lhs.createdAt < rhs.createdAt
    }

    // MARK: - Actions

    /// The action hierarchy for one task.
    ///
    /// `hasOutput` is whether a run left something worth reading, and
    /// `isRunningHere` is whether *Tokenmax* is running it — a task can be
    /// `.running` because the user opened a terminal for it, in which case there
    /// is no process to stop and the useful action is to mark it done.
    static func actions(
        for task: TokenmaxTask,
        hasOutput: Bool,
        isRunningHere: Bool
    ) -> TaskActionSet {
        switch task.status {
        case .ready:
            TaskActionSet(
                primary: .runWithClaude,
                secondary: [.edit, .copyPrompt],
                overflow: [.openInTerminal, .moveToTop, .duplicate, .archive, .delete]
            )

        case .running:
            TaskActionSet(
                primary: isRunningHere ? .stop : .markComplete,
                secondary: hasOutput ? [.viewOutput] : [],
                overflow: isRunningHere
                    ? [.edit, .duplicate]
                    : [.edit, .duplicate, .retry, .archive, .delete]
            )

        case .completed:
            TaskActionSet(
                primary: hasOutput ? .viewResult : .retry,
                secondary: hasOutput ? [.retry] : [],
                overflow: [.edit, .copyPrompt, .duplicate, .archive, .delete]
            )

        case .needsAttention:
            TaskActionSet(
                primary: .retry,
                secondary: hasOutput ? [.edit, .viewError] : [.edit],
                overflow: [.copyPrompt, .openInTerminal, .duplicate, .archive, .delete]
            )

        case .archived:
            TaskActionSet(
                primary: .restore,
                secondary: hasOutput ? [.viewResult] : [],
                overflow: [.edit, .copyPrompt, .duplicate, .delete]
            )
        }
    }

    // MARK: - Manual reordering

    /// The `sortIndex` each ready task should have after a drag.
    ///
    /// `offsets` and `destination` index into `readyTasks` as the list showed
    /// it. The result is contiguous from zero, which makes manual order *total*:
    /// after a drag, `sortIndex` alone decides position and the priority
    /// tiebreak in `TaskStore.readyTasks` no longer applies to these tasks. That
    /// is deliberate — a user who has just dragged a low-priority task to the
    /// top means it, and having priority pull it straight back down would make
    /// the gesture look broken.
    ///
    /// Only tasks whose index actually changes appear in the result, so a drag
    /// that lands where it started touches nothing.
    static func reordered(
        _ readyTasks: [TokenmaxTask],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [UUID: Double] {
        var ordered = readyTasks
        ordered.move(fromOffsets: offsets, toOffset: destination)

        return ordered.enumerated().reduce(into: [:]) { result, pair in
            let (position, task) = pair
            guard task.sortIndex != Double(position) else { return }
            result[task.id] = Double(position)
        }
    }

    // MARK: - Text

    /// "1 task" / "2 tasks", without pulling in a formatter for the two cases
    /// that actually occur.
    static func pluralized(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        let word = count == 1 ? singular : (plural ?? singular + "s")
        return "\(count) \(word)"
    }

    /// The queue's one-line state: `1 ready · 1 running · 2 needing attention`.
    ///
    /// Zero counts stay in rather than being dropped. A line that changes shape
    /// as counts hit zero is harder to read at a glance than one that does not,
    /// and "0 needing attention" is a useful thing to be told.
    static func statusSummary(_ tasks: [TokenmaxTask]) -> String {
        let counts = counts(tasks)
        return [
            "\(counts[.ready] ?? 0) ready",
            "\(counts[.running] ?? 0) running",
            pluralized(counts[.needsAttention] ?? 0, "needing attention", "needing attention"),
        ].joined(separator: " · ")
    }
}
