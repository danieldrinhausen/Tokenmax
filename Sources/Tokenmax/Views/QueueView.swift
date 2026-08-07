import AppKit
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator

    @Environment(\.dismiss) private var dismiss

    /// View preferences, kept in UserDefaults rather than in `tokenmax.json`.
    /// Which filter the user last looked at is not a property of their tasks,
    /// and writing it into the task file would mean every glance at the window
    /// rewrote the queue.
    @AppStorage("queue.filter") private var filter: QueueFilter = .ready
    @AppStorage("queue.sort") private var sort: QueueSort = .queueOrder
    /// Which provider's tasks to show, as a raw value because AppStorage cannot
    /// hold an optional enum. Empty is "all providers".
    @AppStorage("queue.provider") private var providerFilterID = ""

    /// Deliberately not persisted: reopening the window to a filtered list with
    /// no obvious cause is worse than retyping four characters.
    @State private var query = ""

    @State private var editingTask: TokenmaxTask?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var viewingRun: TaskRunRecord?
    @State private var directories = DirectoryExistenceCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QueueHeaderView(
                quotas: providerQuotas,
                now: usage.tick,
                tasks: taskStore.tasks,
                burnOpportunity: usage.burnOpportunity,
                highlight: settingsStore.settings.menuBarHighlightColor.color,
                isRefreshing: usage.isRefreshing,
                runNextBlock: autoRun.decision.skipReason,
                canRunNext: canRunNext,
                onNewTask: { isCreating = true },
                onRunNext: runNext,
                onRefresh: refresh,
                onOpenTerminal: openTerminal
            )

            Divider()

            autoRunBanner
            controls
            Divider()

            content
        }
        .frame(minWidth: 620, minHeight: 480)
        // The scene stays registered so the window id remains resolvable; the
        // setting is enforced here instead. Switching the queue off with this
        // window open would otherwise leave an orphaned window for a feature
        // that is no longer reachable from anywhere else.
        .onChange(of: settingsStore.settings.queueEnabled) { _, enabled in
            if !enabled { dismiss() }
        }
        .sheet(isPresented: $isCreating) {
            TaskEditorView(task: newTaskDraft) { newTask in
                taskStore.add(newTask)
                directories.invalidate()
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task) { updated in
                taskStore.update(updated)
                // The user may have just pointed the task somewhere else, and
                // the card should not keep reporting the old directory's state.
                directories.invalidate()
            }
        }
        .sheet(item: $viewingRun) { run in
            // Passed explicitly rather than relying on sheet inheritance: the
            // reply field needs the coordinator, and a missing environment
            // object is a crash rather than a degraded view.
            RunOutputView(record: run)
                .environmentObject(autoRun)
        }
        // "View Output" from a notification has no task context, so it opens
        // whatever ran most recently.
        .onReceive(NotificationCenter.default.publisher(for: .tokenmaxAutoRunViewOutput)) { _ in
            viewingRun = autoRun.lastRun
        }
        .alert("Could not run task", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chrome

    /// A blank task carrying the configured provider, model, thinking and budget
    /// defaults, so the common choice is made once in Settings rather than on
    /// every task.
    ///
    /// Both providers' policies are seeded regardless of which one is the
    /// default: switching the provider in the editor then lands on the settings
    /// the user chose for it, rather than on bare struct defaults.
    private var newTaskDraft: TokenmaxTask {
        let settings = settingsStore.settings
        var task = TokenmaxTask(title: "", prompt: "")
        task.providerID = settings.defaultTaskProvider.rawValue
        task.autoRun.model = settings.defaultTaskModel
        task.autoRun.effort = settings.defaultTaskEffort
        task.autoRun.maximumBudgetUSD = settings.defaultTaskBudgetUSD
        task.codex.model = settings.defaultCodexModel
        task.codex.reasoningEffort = settings.defaultCodexReasoningEffort
        task.codex.sandbox = settings.defaultCodexSandbox
        return task
    }

    /// One entry per provider the user is still monitoring, in canonical order.
    /// The header lays them out side by side when the window has room.
    private var providerQuotas: [QueueHeaderView.ProviderQuota] {
        settingsStore.settings.enabledProviders.map { provider in
            QueueHeaderView.ProviderQuota(
                provider: provider,
                state: usage.state(for: provider),
                isStale: usage.isStale(for: provider),
                onRefresh: {
                    Task { await usage.refresh(reason: "queue", manual: true, provider: provider) }
                }
            )
        }
    }

    private var autoRunBanner: some View {
        AutoRunStatusBannerView(
            pendingRun: autoRun.pendingRun,
            activeRun: autoRun.activeRun,
            progressText: autoRun.progressText,
            isPausedAfterFailure: autoRun.isPausedAfterFailure,
            awaitingFreshUsage: autoRun.awaitingFreshUsage,
            now: usage.tick,
            onStartNow: { autoRun.startPendingNow() },
            onCancelPending: { autoRun.cancelPending() },
            onStop: { autoRun.stop() },
            onResume: { autoRun.resumeAfterFailure() }
        )
    }

    /// Navigation and search on one row when there is room, stacked when there
    /// is not.
    ///
    /// `ViewThatFits` rather than a fixed layout because the two filter groups
    /// and the search field together want about 830pt, and the window can be
    /// narrower than that. Left to an HStack, the overflow does not compress —
    /// it renders off the leading edge and takes the header's alignment with
    /// it, because the widest row is what the enclosing column sizes to.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                navigation
                Spacer(minLength: 12)
                searchAndSort
            }

            VStack(alignment: .leading, spacing: 10) {
                navigation
                searchAndSort
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Whether the cards should name their provider.
    ///
    /// Only when the queue is actually mixed — reading the tasks rather than the
    /// enabled providers, because someone who runs both providers but queues
    /// only Claude work has a uniform queue and gains nothing from a badge on
    /// every card. Suppressed while the list is filtered to one provider, where
    /// the filter above already says which.
    private var showsProviderOnCards: Bool {
        guard providerFilter.wrappedValue == nil else { return false }
        return Set(taskStore.tasks.map(\.providerID)).count > 1
    }

    /// Bridges the stored raw value to the picker's optional.
    ///
    /// Reads as "all providers" for anything unrecognised, so a provider removed
    /// from a future build cannot leave the queue looking permanently empty.
    private var providerFilter: Binding<TokenmaxProvider?> {
        Binding(
            get: { TokenmaxProvider.from(identifier: providerFilterID) },
            set: { providerFilterID = $0?.rawValue ?? "" }
        )
    }

    private var navigation: some View {
        QueueNavigationView(filter: $filter, tasks: taskStore.tasks)
    }

    private var searchAndSort: some View {
        QueueSearchAndSortView(
            query: $query,
            sort: $sort,
            provider: providerFilter,
            providerOptions: settingsStore.settings.enabledProviders,
            canReorder: canReorder
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if visibleTasks.isEmpty {
            QueueEmptyStateView(
                filter: filter,
                query: query,
                isFirstRun: isFirstRun,
                onNewTask: { isCreating = true },
                onClearSearch: { query = "" },
                onOpenTerminal: openTerminal,
                onRefresh: refresh
            )
        } else {
            taskList
        }
    }

    private var taskList: some View {
        // Only offered where it means something: reordering a list sorted by
        // priority would either be discarded on the next redraw or quietly
        // rewrite the priority the user set.
        var moveHandler: ((IndexSet, Int) -> Void)?
        if canReorder {
            moveHandler = { offsets, destination in
                taskStore.move(fromOffsets: offsets, toOffset: destination)
            }
        }

        // Deliberately no `selection:` binding. A plain List paints the selected
        // row edge-to-edge in the accent colour, and `.listRowBackground` does
        // not override it — the card, which is the whole point of the redesign,
        // disappears under a blue slab the moment a row is clicked. Row-level
        // arrow-key navigation is the cost; the buttons inside each card remain
        // reachable by Tab, which is the keyboard path that actually does
        // something. See the deferred note in the summary.
        return List {
            ForEach(visibleTasks) { task in
                card(for: task)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .onMove(perform: moveHandler)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func card(for task: TokenmaxTask) -> some View {
        let isRunningHere = autoRun.activeRun?.taskID == task.id
        let progress: String? = isRunningHere ? (autoRun.progressText ?? "Running…") : nil

        return TaskCardView(
            task: task,
            autoRunBlock: eligibility[task.id],
            directoryExists: directories.exists(task, now: usage.tick),
            showsProvider: showsProviderOnCards,
            isRunningHere: isRunningHere,
            runProgress: progress,
            lastRun: autoRun.lastRun(forTask: task.id),
            now: usage.tick,
            canReorder: canReorder,
            onEdit: { editingTask = task },
            onCopy: { ManualRunService.copyPrompt(task) },
            onOpenInTerminal: { openInTerminal(task) },
            onRunWithProvider: { runWithProvider(task) },
            onStop: { autoRun.stop() },
            onViewOutput: { viewOutput(task) },
            onComplete: { taskStore.setStatus(.completed, for: task) },
            onRetry: { taskStore.setStatus(.ready, for: task) },
            onRestore: { taskStore.setStatus(.ready, for: task) },
            onMoveToTop: { taskStore.moveToTop(task) },
            onDuplicate: { taskStore.duplicate(task) },
            onArchive: { taskStore.setStatus(.archived, for: task) },
            onDelete: { taskStore.delete(task) }
        )
    }

    // MARK: - Derived

    private var visibleTasks: [TokenmaxTask] {
        QueueListModel.visible(
            tasks: taskStore.tasks,
            filter: filter,
            query: query,
            sort: sort,
            provider: providerFilter.wrappedValue
        )
    }

    /// One eligibility snapshot for the whole list rather than one per card —
    /// see `QueueAutoRunCoordinator.eligibilityMap`. Only the Ready band shows
    /// it, so nothing else pays for it.
    private var eligibility: [UUID: QueueAutoRunDecision.SkipReason] {
        guard filter == .ready else { return [:] }
        return autoRun.eligibilityMap(for: visibleTasks)
    }

    private var canReorder: Bool {
        filter == .ready && sort.supportsManualReordering && query.isEmpty
    }

    /// Disabled while anything is in flight. The coordinator would refuse a
    /// second run anyway; the button should not invite the click.
    private var canRunNext: Bool {
        autoRun.activeRun == nil && autoRun.pendingRun == nil && taskStore.readyCount > 0
    }

    /// Nothing has ever been read and nothing has been queued — so the window
    /// has room to explain what Tokenmax is for instead of showing an empty box.
    private var isFirstRun: Bool {
        usage.state.snapshot == nil && taskStore.tasks.isEmpty
    }

    // MARK: - Actions

    private func refresh() {
        directories.invalidate()
        Task { await usage.refresh(reason: "queue window", manual: true) }
    }

    /// Backs "Run Next".
    ///
    /// The eligibility logic is not reimplemented here: the coordinator decides,
    /// re-checking every gate including the ones that cost a subprocess, and
    /// hands back the reason when it refuses.
    private func runNext() {
        if let reason = autoRun.runNextEligibleNow() {
            errorMessage = reason.explanation
        }
    }

    /// The 0.1 behaviour, kept: copy the prompt and open a terminal so the user
    /// drives the session themselves.
    ///
    /// The task is marked `.running` only after the terminal is confirmed open.
    /// A misconfigured terminal used to leave a task marked running against a
    /// session that never started.
    private func openInTerminal(_ task: TokenmaxTask) {
        Task {
            do {
                try await ManualRunService.run(
                    task,
                    terminalApplication: settingsStore.settings.terminalApplication
                )
                taskStore.setStatus(.running, for: task)
            } catch {
                errorMessage = error.localizedDescription
                taskStore.markNeedsAttention(task, message: error.localizedDescription)
            }
        }
    }

    /// Runs the task headlessly through its selected provider, here and now.
    ///
    /// Deliberately does not require the task to be marked for automation:
    /// pressing this button *is* the approval, and demanding the safe default be
    /// switched off first would make it impossible to test a task before
    /// trusting it to run unattended.
    private func runWithProvider(_ task: TokenmaxTask) {
        if let reason = autoRun.runManually(task) {
            errorMessage = reason.explanation
        }
    }

    private func viewOutput(_ task: TokenmaxTask) {
        viewingRun = autoRun.lastRun(forTask: task.id)
    }

    /// Opens the user's configured terminal at their home directory, as a
    /// recovery action for the states that are fixed by running `claude`.
    private func openTerminal() {
        ManualRunService.openTerminalForRecovery(
            application: settingsStore.settings.terminalApplication
        )
    }
}
