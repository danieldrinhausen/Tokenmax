import AppKit
import SwiftUI

enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case ready = "Ready"
    case running = "Running"
    case completed = "Completed"
    case needsAttention = "Needs Attention"

    var id: String { rawValue }

    var status: TaskStatus? {
        switch self {
        case .all: nil
        case .ready: .ready
        case .running: .running
        case .completed: .completed
        case .needsAttention: .needsAttention
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var usage: UsageRefreshCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator

    @Environment(\.dismiss) private var dismiss

    @State private var filter: QueueFilter = .ready
    @State private var editingTask: TokenmaxTask?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var viewingRun: TaskRunRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            automationBanner
            filterBar
            Divider()

            if visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleTasks) { task in
                            TaskCardView(
                                task: task,
                                autoRunBlock: autoRun.eligibility(for: task),
                                runProgress: autoRun.activeRun?.taskID == task.id
                                    ? (autoRun.progressText ?? "Running…") : nil,
                                lastRun: autoRun.lastRun(forTask: task.id),
                                onEdit: { editingTask = task },
                                onCopy: { ManualRunService.copyPrompt(task) },
                                onRun: { run(task) },
                                onRunWithClaude: { runWithClaude(task) },
                                onStop: { autoRun.stop() },
                                onViewOutput: { viewOutput(task) },
                                onComplete: { taskStore.setStatus(.completed, for: task) },
                                onRetry: { taskStore.setStatus(.ready, for: task) },
                                onMoveToTop: { taskStore.moveToTop(task) },
                                onDuplicate: { taskStore.duplicate(task) },
                                onArchive: { taskStore.setStatus(.archived, for: task) },
                                onDelete: { taskStore.delete(task) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        // The scene stays registered so the window id remains resolvable; the
        // setting is enforced here instead. Switching the queue off with this
        // window open would otherwise leave an orphaned window for a feature
        // that is no longer reachable from anywhere else.
        .onChange(of: settingsStore.settings.queueEnabled) { _, enabled in
            if !enabled { dismiss() }
        }
        .sheet(isPresented: $isCreating) {
            TaskEditorView(task: TokenmaxTask(title: "", prompt: "")) { newTask in
                taskStore.add(newTask)
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorView(task: task) { updated in
                taskStore.update(updated)
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tokenmax").font(.system(size: 15, weight: .semibold))
                Text(usageLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isCreating = true
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(16)
    }

    private var usageLine: String {
        guard let session = usage.state.snapshot?.sessionWindow,
              let remaining = session.remainingPercent
        else {
            return "Claude Code · usage unavailable"
        }
        let staleSuffix = usage.isStale ? " · stale" : ""
        guard !usage.isStale, let resetAt = session.resetAt else {
            return "Claude Code · \(Int(remaining.rounded()))% left\(staleSuffix)"
        }
        let interval = resetAt.timeIntervalSince(usage.tick)
        guard interval > 0 else { return "Claude Code · \(Int(remaining.rounded()))% left" }
        return "Claude Code · \(Int(remaining.rounded()))% left · resets in \(RelativeTime.countdown(interval))"
    }

    /// The countdown, the live run, and the paused state — the three things
    /// that need to be visible the moment the queue window is opened.
    @ViewBuilder
    private var automationBanner: some View {
        if let pending = autoRun.pendingRun {
            banner(icon: "timer", tint: .orange) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Starting “\(pending.taskTitle)” in \(pending.secondsRemaining(now: usage.tick))s")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Tokenmax will run this task with Claude Code.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                HStack(spacing: 6) {
                    Button("Start Now") { autoRun.startPendingNow() }
                    Button("Cancel") { autoRun.cancelPending() }
                }
                .font(.system(size: 11))
            }
        } else if let run = autoRun.activeRun {
            banner(icon: "play.circle", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running “\(run.taskTitle)”")
                        .font(.system(size: 11, weight: .semibold))
                    Text(autoRun.progressText ?? "Working…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } trailing: {
                Button("Stop") { autoRun.stop() }
                    .font(.system(size: 11))
            }
        } else if autoRun.isPausedAfterFailure {
            banner(icon: "exclamationmark.triangle", tint: .orange) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Queue paused after a failure")
                        .font(.system(size: 11, weight: .semibold))
                    Text("No further task will start automatically this session.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Resume") { autoRun.resumeAfterFailure() }
                    .font(.system(size: 11))
            }
        } else if autoRun.awaitingFreshUsage {
            banner(icon: "clock.arrow.circlepath", tint: .secondary) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Waiting for a fresh quota reading")
                        .font(.system(size: 11, weight: .semibold))
                    Text("The last task finished. Nothing else starts until the numbers catch up.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } trailing: { EmptyView() }
        }
    }

    private func banner(
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            content()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(QueueFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Text("\(option.rawValue)\(countSuffix(for: option))")
                        .font(.system(size: 11, weight: filter == option ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            filter == option ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func countSuffix(for option: QueueFilter) -> String {
        guard let status = option.status else { return "" }
        let count = taskStore.tasks(withStatus: status).count
        return count > 0 ? " \(count)" : ""
    }

    private var visibleTasks: [TokenmaxTask] {
        guard let status = filter.status else {
            return taskStore.tasks
                .filter { $0.status != .archived }
                .sorted { $0.sortIndex < $1.sortIndex }
        }
        if status == .ready { return taskStore.readyTasks }
        return taskStore.tasks(withStatus: status).sorted { $0.updatedAt > $1.updatedAt }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(filter == .ready ? "No tasks ready" : "Nothing in \(filter.rawValue)")
                .font(.system(size: 13, weight: .medium))
            if filter == .ready {
                Text("Add prompts through the day so leftover quota has somewhere to go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func run(_ task: TokenmaxTask) {
        do {
            try ManualRunService.run(task, terminalApplication: settingsStore.settings.terminalApplication)
            taskStore.setStatus(.running, for: task)
        } catch {
            errorMessage = error.localizedDescription
            taskStore.markNeedsAttention(task, message: error.localizedDescription)
        }
    }

    /// Runs the task headlessly through Claude Code, here and now.
    ///
    /// Deliberately does not require the task to be marked for automation:
    /// pressing this button *is* the approval, and demanding the safe default be
    /// switched off first would make it impossible to test a task before
    /// trusting it to run unattended.
    private func runWithClaude(_ task: TokenmaxTask) {
        if let reason = autoRun.runManually(task) {
            errorMessage = reason.explanation
        }
    }

    private func viewOutput(_ task: TokenmaxTask) {
        viewingRun = autoRun.lastRun(forTask: task.id)
    }
}
