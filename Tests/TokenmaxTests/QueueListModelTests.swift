import Foundation
import Testing

@testable import Tokenmax

/// The queue window's presentation logic, tested without SwiftUI.
///
/// Filtering, searching, sorting, and the per-state action hierarchy all live in
/// `QueueListModel` precisely so they can be asserted here rather than eyeballed
/// in a running window.
@Suite("Queue list model")
struct QueueListModelTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    // MARK: - Builders

    private func task(
        _ title: String,
        status: TaskStatus = .ready,
        priority: TaskPriority = .medium,
        prompt: String = "Do the thing.",
        project: String? = nil,
        directory: String? = nil,
        sortIndex: Double = 0,
        createdOffset: TimeInterval = 0,
        updatedOffset: TimeInterval = 0,
        completedOffset: TimeInterval? = nil
    ) -> TokenmaxTask {
        var task = TokenmaxTask(
            title: title,
            prompt: prompt,
            projectName: project,
            workingDirectory: directory,
            priority: priority,
            status: status,
            sortIndex: sortIndex
        )
        task.createdAt = now.addingTimeInterval(createdOffset)
        task.updatedAt = now.addingTimeInterval(updatedOffset)
        task.completedAt = completedOffset.map { now.addingTimeInterval($0) }
        return task
    }

    // MARK: - Sections

    @Test("Active work and history are separate bands")
    func filtersSplitIntoSections() {
        #expect(QueueFilter.cases(in: .queue) == [.ready, .running, .needsAttention])
        #expect(QueueFilter.cases(in: .history) == [.completed, .archived])
        // Every filter belongs to exactly one band, so navigation cannot lose one.
        #expect(QueueFilter.allCases.count == QueueFilter.cases(in: .queue).count
            + QueueFilter.cases(in: .history).count)
    }

    @Test("Every task status has a filter that shows it")
    func everyStatusIsReachable() {
        for status in TaskStatus.allCases {
            #expect(QueueFilter.allCases.contains { $0.status == status })
        }
    }

    // MARK: - Counts

    @Test("Counts are reported per status, including zero")
    func countsPerStatus() {
        let tasks = [
            task("a", status: .ready),
            task("b", status: .ready),
            task("c", status: .running),
            task("d", status: .completed),
        ]

        #expect(QueueListModel.count(tasks, .ready) == 2)
        #expect(QueueListModel.count(tasks, .running) == 1)
        #expect(QueueListModel.count(tasks, .completed) == 1)
        // The zero is the point: the segment still has to render a number.
        #expect(QueueListModel.count(tasks, .needsAttention) == 0)
        #expect(QueueListModel.count(tasks, .archived) == 0)
    }

    @Test("An empty queue counts zero everywhere rather than crashing")
    func countsOnEmptyQueue() {
        for filter in QueueFilter.allCases {
            #expect(QueueListModel.count([], filter) == 0)
        }
    }

    // MARK: - Search

    @Test("Search matches the title")
    func searchMatchesTitle() {
        #expect(QueueListModel.matches(task("Overview V2"), query: "overview"))
        #expect(!QueueListModel.matches(task("Overview V2"), query: "invoice"))
    }

    @Test("Search matches the prompt")
    func searchMatchesPrompt() {
        let subject = task("Untitled", prompt: "Create a 5 bullet point overview.")
        #expect(QueueListModel.matches(subject, query: "bullet point"))
    }

    @Test("Search matches the project name")
    func searchMatchesProject() {
        let subject = task("Anything", prompt: "x", project: "Tokenmax")
        #expect(QueueListModel.matches(subject, query: "tokenmax"))
    }

    @Test("Search matches the working directory")
    func searchMatchesWorkingDirectory() {
        let subject = task("Anything", prompt: "x", directory: "~/Documents/Git Repositories/Tokenmax")
        #expect(QueueListModel.matches(subject, query: "Git Repositories"))
    }

    @Test("Search matches an expanded path the card never displays")
    func searchMatchesExpandedPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let subject = task("Anything", prompt: "x", directory: "~/Projects/App")
        // Typing the absolute path should find a task stored with a tilde.
        #expect(QueueListModel.matches(subject, query: "\(home)/Projects"))
    }

    @Test("Search ignores case and diacritics")
    func searchIsInsensitive() {
        let subject = task("Überproject", prompt: "x")
        #expect(QueueListModel.matches(subject, query: "uberproject"))
        #expect(QueueListModel.matches(subject, query: "ÜBERPROJECT"))
    }

    @Test("An empty or whitespace query matches everything")
    func emptyQueryMatchesAll() {
        let subject = task("Anything")
        #expect(QueueListModel.matches(subject, query: ""))
        #expect(QueueListModel.matches(subject, query: "   "))
    }

    @Test("A query that matches nothing returns nothing")
    func searchCanMissEverything() {
        let tasks = [task("Overview"), task("Invoices")]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, query: "zzz")
        #expect(visible.isEmpty)
    }

    @Test("Search does not leak tasks across filters")
    func searchRespectsTheFilter() {
        let tasks = [
            task("Overview", status: .ready),
            task("Overview", status: .completed),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, query: "overview")
        #expect(visible.count == 1)
        #expect(visible.first?.status == .ready)
    }

    // MARK: - Sorting

    @Test("Queue order is manual order, then priority, then age")
    func queueOrderSorting() {
        let tasks = [
            task("third", priority: .low, sortIndex: 2),
            task("first", priority: .low, sortIndex: 0),
            task("second", priority: .low, sortIndex: 1),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, sort: .queueOrder)
        #expect(visible.map(\.title) == ["first", "second", "third"])
    }

    @Test("Queue order matches what the auto-runner will pick up")
    func queueOrderMatchesReadyTasks() {
        // Same tie-breaking as `TaskStore.readyTasks`: equal sortIndex falls to
        // priority, then to creation date. If these two ever disagree, the top
        // of the Ready list stops being the task "Run Next" would start.
        let tasks = [
            task("older medium", priority: .medium, sortIndex: 0, createdOffset: -100),
            task("urgent", priority: .urgent, sortIndex: 0, createdOffset: 0),
            task("newer medium", priority: .medium, sortIndex: 0, createdOffset: 100),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, sort: .queueOrder)
        #expect(visible.map(\.title) == ["urgent", "older medium", "newer medium"])
    }

    @Test("Priority sorting puts urgent first and keeps queue order within a tier")
    func prioritySorting() {
        let tasks = [
            task("low", priority: .low, sortIndex: 0),
            task("urgent", priority: .urgent, sortIndex: 3),
            task("high b", priority: .high, sortIndex: 2),
            task("high a", priority: .high, sortIndex: 1),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, sort: .priority)
        #expect(visible.map(\.title) == ["urgent", "high a", "high b", "low"])
    }

    @Test("Recently updated sorts newest first")
    func recentlyUpdatedSorting() {
        let tasks = [
            task("old", updatedOffset: -300),
            task("new", updatedOffset: 0),
            task("middle", updatedOffset: -100),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .ready, sort: .recentlyUpdated)
        #expect(visible.map(\.title) == ["new", "middle", "old"])
    }

    @Test("Recently completed sorts finished work first and unfinished work last")
    func recentlyCompletedSorting() {
        let tasks = [
            task("finished earlier", status: .completed, completedOffset: -300),
            task("never finished", status: .completed, completedOffset: nil),
            task("finished just now", status: .completed, completedOffset: 0),
        ]
        let visible = QueueListModel.visible(tasks: tasks, filter: .completed, sort: .recentlyCompleted)
        #expect(visible.map(\.title) == ["finished just now", "finished earlier", "never finished"])
    }

    @Test("Sorting never adds or drops a task")
    func sortingPreservesMembership() {
        let tasks = [
            task("a", sortIndex: 1),
            task("b", sortIndex: 0),
            task("c", sortIndex: 2),
        ]
        for sort in QueueSort.allCases {
            let visible = QueueListModel.visible(tasks: tasks, filter: .ready, sort: sort)
            #expect(Set(visible.map(\.id)) == Set(tasks.map(\.id)), "\(sort) lost or invented a task")
        }
    }

    @Test("Only queue order can be dragged")
    func onlyQueueOrderIsDraggable() {
        #expect(QueueSort.queueOrder.supportsManualReordering)
        #expect(!QueueSort.priority.supportsManualReordering)
        #expect(!QueueSort.recentlyUpdated.supportsManualReordering)
        #expect(!QueueSort.recentlyCompleted.supportsManualReordering)
    }

    // MARK: - Manual reordering

    @Test("Dragging a task down renumbers the ready queue contiguously")
    func dragDownRenumbers() {
        let tasks = [
            task("a", sortIndex: 0),
            task("b", sortIndex: 1),
            task("c", sortIndex: 2),
        ]
        let updates = QueueListModel.reordered(tasks, fromOffsets: IndexSet(integer: 0), toOffset: 3)

        // a → last, so b and c each shift up one and a lands at 2.
        #expect(updates[tasks[0].id] == 2)
        #expect(updates[tasks[1].id] == 0)
        #expect(updates[tasks[2].id] == 1)
    }

    @Test("Dragging a task to the top gives it the lowest index")
    func dragToTopRenumbers() {
        let tasks = [
            task("a", sortIndex: 0),
            task("b", sortIndex: 1),
            task("c", sortIndex: 2),
        ]
        let updates = QueueListModel.reordered(tasks, fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(updates[tasks[2].id] == 0)
        #expect(updates[tasks[0].id] == 1)
        #expect(updates[tasks[1].id] == 2)
    }

    @Test("A drag that changes nothing writes nothing")
    func noOpDragWritesNothing() {
        let tasks = [
            task("a", sortIndex: 0),
            task("b", sortIndex: 1),
            task("c", sortIndex: 2),
        ]
        // Moving item 0 to offset 0 is where it already was.
        let updates = QueueListModel.reordered(tasks, fromOffsets: IndexSet(integer: 0), toOffset: 0)
        #expect(updates.isEmpty)
    }

    @Test("Manual order beats priority once a task has been dragged")
    func manualOrderOverridesPriority() {
        // The behaviour a drag has to have: a low-priority task dragged to the
        // top stays at the top. Contiguous indices are what make that true.
        let tasks = [
            task("urgent", priority: .urgent, sortIndex: 0),
            task("low", priority: .low, sortIndex: 1),
        ]
        let updates = QueueListModel.reordered(tasks, fromOffsets: IndexSet(integer: 1), toOffset: 0)

        var reordered = tasks
        for index in reordered.indices {
            if let sortIndex = updates[reordered[index].id] { reordered[index].sortIndex = sortIndex }
        }

        let visible = QueueListModel.visible(tasks: reordered, filter: .ready, sort: .queueOrder)
        #expect(visible.map(\.title) == ["low", "urgent"])
    }

    // MARK: - Actions

    @Test("Every state offers exactly one primary action")
    func onePrimaryActionPerState() {
        for status in TaskStatus.allCases {
            for hasOutput in [true, false] {
                let actions = QueueListModel.actions(
                    for: task("t", status: status),
                    hasOutput: hasOutput,
                    isRunningHere: status == .running
                )
                // The primary must not also appear lower down, or the card shows
                // the same action twice at two different weights.
                #expect(!actions.secondary.contains(actions.primary))
                #expect(!actions.overflow.contains(actions.primary))
            }
        }
    }

    @Test("No action is offered twice on one card")
    func actionsAreUnique() {
        for status in TaskStatus.allCases {
            for hasOutput in [true, false] {
                let actions = QueueListModel.actions(
                    for: task("t", status: status),
                    hasOutput: hasOutput,
                    isRunningHere: true
                )
                #expect(Set(actions.all).count == actions.all.count, "\(status) duplicates an action")
            }
        }
    }

    @Test("A ready task leads with Run with Provider")
    func readyActions() {
        let actions = QueueListModel.actions(for: task("t"), hasOutput: false, isRunningHere: false)
        #expect(actions.primary == .runWithProvider)
        #expect(actions.secondary == [.edit, .copyPrompt])
    }

    /// A mixed queue is the whole point of the filter, so it must narrow to one
    /// provider without touching the status filter it sits beside.
    @Test("The provider filter is orthogonal to the status filter")
    func providerFilterNarrowsWithoutChangingStatus() {
        var claudeTask = TokenmaxTask(title: "Claude work", prompt: "Do it", status: .ready)
        var codexTask = TokenmaxTask(title: "Codex work", prompt: "Do it", status: .ready)
        codexTask.providerID = TokenmaxProvider.codex.rawValue
        var doneTask = TokenmaxTask(title: "Finished", prompt: "Done", status: .completed)
        doneTask.providerID = TokenmaxProvider.codex.rawValue
        claudeTask.sortIndex = 0
        codexTask.sortIndex = 1
        let tasks = [claudeTask, codexTask, doneTask]

        func titles(_ provider: TokenmaxProvider?) -> [String] {
            QueueListModel.visible(tasks: tasks, filter: .ready, provider: provider).map(\.title)
        }

        // nil is every provider, which is what an unfiltered queue shows.
        #expect(titles(nil) == ["Claude work", "Codex work"])
        #expect(titles(.claudeCode) == ["Claude work"])
        // The completed Codex task stays out: the status filter still applies.
        #expect(titles(.codex) == ["Codex work"])
    }

    @Test("A task Tokenmax is running leads with Stop")
    func runningActions() {
        let actions = QueueListModel.actions(
            for: task("t", status: .running), hasOutput: true, isRunningHere: true
        )
        #expect(actions.primary == .stop)
        #expect(actions.secondary.contains(.viewOutput))
    }

    @Test("A task running in a terminal offers Mark Complete, not Stop")
    func runningInTerminalActions() {
        // Nothing to stop: the user is driving that session themselves, and a
        // Stop button that cannot stop anything is worse than none.
        let actions = QueueListModel.actions(
            for: task("t", status: .running), hasOutput: false, isRunningHere: false
        )
        #expect(actions.primary == .markComplete)
        #expect(!actions.all.contains(.stop))
    }

    @Test("A completed task leads with View Result when there is one")
    func completedActions() {
        let actions = QueueListModel.actions(
            for: task("t", status: .completed), hasOutput: true, isRunningHere: false
        )
        #expect(actions.primary == .viewResult)
        #expect(actions.secondary == [.retry])
    }

    @Test("A completed task with no output leads with Retry instead")
    func completedWithoutOutputActions() {
        let actions = QueueListModel.actions(
            for: task("t", status: .completed), hasOutput: false, isRunningHere: false
        )
        #expect(actions.primary == .retry)
        #expect(!actions.all.contains(.viewResult))
    }

    @Test("A failing task leads with Retry and offers the error")
    func needsAttentionActions() {
        let actions = QueueListModel.actions(
            for: task("t", status: .needsAttention), hasOutput: true, isRunningHere: false
        )
        #expect(actions.primary == .retry)
        #expect(actions.secondary.contains(.edit))
        #expect(actions.secondary.contains(.viewError))
    }

    @Test("An archived task leads with Restore")
    func archivedActions() {
        let actions = QueueListModel.actions(
            for: task("t", status: .archived), hasOutput: true, isRunningHere: false
        )
        #expect(actions.primary == .restore)
        #expect(actions.overflow.contains(.delete))
    }

    @Test("Delete is always destructive and always buried in the overflow")
    func deleteStaysInTheOverflow() {
        for status in TaskStatus.allCases {
            let actions = QueueListModel.actions(
                for: task("t", status: status), hasOutput: true, isRunningHere: false
            )
            #expect(actions.primary != .delete)
            #expect(!actions.secondary.contains(.delete))
        }
        #expect(TaskAction.delete.isDestructive)
        #expect(!TaskAction.archive.isDestructive)
    }

    @Test("Archive is never offered while Tokenmax is running the task")
    func noArchiveMidRun() {
        // Archiving a task out from under a live process would leave the run
        // recording a task the queue no longer shows.
        let actions = QueueListModel.actions(
            for: task("t", status: .running), hasOutput: false, isRunningHere: true
        )
        #expect(!actions.all.contains(.archive))
        #expect(!actions.all.contains(.delete))
    }

    @Test("Output actions are hidden when a run left nothing to read")
    func noOutputActionsWithoutOutput() {
        for status in TaskStatus.allCases {
            let actions = QueueListModel.actions(
                for: task("t", status: status), hasOutput: false, isRunningHere: status == .running
            )
            #expect(!actions.all.contains(.viewResult), "\(status) offers a result that does not exist")
            #expect(!actions.all.contains(.viewOutput), "\(status) offers output that does not exist")
            #expect(!actions.all.contains(.viewError), "\(status) offers an error that does not exist")
        }
    }

    // MARK: - Text

    @Test("Counts are pluralized correctly at zero, one, and many")
    func pluralization() {
        #expect(QueueListModel.pluralized(0, "task") == "0 tasks")
        #expect(QueueListModel.pluralized(1, "task") == "1 task")
        #expect(QueueListModel.pluralized(2, "task") == "2 tasks")
    }

    @Test("The status line reads as a sentence and keeps its zeroes")
    func statusSummaryLine() {
        let tasks = [
            task("a", status: .ready),
            task("b", status: .running),
        ]
        #expect(QueueListModel.statusSummary(tasks) == "1 ready · 1 running · 0 needing attention")
    }

    @Test("The status line survives an empty queue")
    func statusSummaryWhenEmpty() {
        #expect(QueueListModel.statusSummary([]) == "0 ready · 0 running · 0 needing attention")
    }
}
