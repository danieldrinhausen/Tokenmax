import SwiftUI

/// One task in the queue, rendered as its state.
///
/// A dispatcher rather than a single configurable card: a ready task and a
/// finished one are asking the user for different things, and giving them the
/// same layout means neither gets the shape it needs. What they share —
/// indicator, title, prompt preview, directory line, action bar — lives in
/// `TaskCardChrome` and `TaskCardActionsView`.
struct TaskCardView: View {
    let task: TokenmaxTask

    /// Why this task cannot be run automatically right now, or nil if it can.
    var autoRunBlock: QueueAutoRunDecision.SkipReason?
    /// Cached rather than read per redraw — see `DirectoryExistenceCache`.
    var directoryExists: Bool
    /// True only when *Tokenmax* is running it. A task can be `.running`
    /// because the user opened a terminal for it, and there is no process to
    /// stop in that case.
    var isRunningHere: Bool
    var runProgress: String?
    var lastRun: TaskRunRecord?
    var now: Date
    var canReorder: Bool

    var onEdit: () -> Void
    var onCopy: () -> Void
    var onOpenInTerminal: () -> Void
    var onRunWithClaude: () -> Void
    var onStop: () -> Void
    var onViewOutput: () -> Void
    var onComplete: () -> Void
    var onRetry: () -> Void
    var onRestore: () -> Void
    var onMoveToTop: () -> Void
    var onDuplicate: () -> Void
    var onArchive: () -> Void
    var onDelete: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if canReorder {
                dragHandle
            }
            card
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.title.isEmpty ? "Untitled task" : task.title), \(task.status.displayName)")
    }

    @ViewBuilder
    private var card: some View {
        switch task.status {
        case .ready:
            ReadyTaskCardView(
                task: task,
                autoRunBlock: autoRunBlock,
                directoryExists: directoryExists,
                actions: actionSet,
                handlers: handlers,
                copied: $copied
            )
        case .running:
            RunningTaskCardView(
                task: task,
                directoryExists: directoryExists,
                isRunningHere: isRunningHere,
                progress: runProgress,
                lastRun: lastRun,
                now: now,
                actions: actionSet,
                handlers: handlers,
                copied: $copied
            )
        case .completed:
            CompletedTaskRowView(
                task: task,
                lastRun: lastRun,
                actions: actionSet,
                handlers: handlers,
                copied: $copied
            )
        case .needsAttention:
            NeedsAttentionTaskCardView(
                task: task,
                directoryExists: directoryExists,
                actions: actionSet,
                handlers: handlers,
                copied: $copied
            )
        case .archived:
            ArchivedTaskRowView(
                task: task,
                actions: actionSet,
                handlers: handlers,
                copied: $copied
            )
        }
    }

    /// Only drawn where dragging actually does something, so its presence is a
    /// truthful signal that the list is reorderable right now.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(width: 12)
            .help("Drag to reorder")
            .accessibilityLabel("Drag to reorder. Use Move to Top from the actions menu instead.")
    }

    private var actionSet: TaskActionSet {
        QueueListModel.actions(for: task, hasOutput: hasOutput, isRunningHere: isRunningHere)
    }

    /// True once a run has produced something worth reading — either a stored
    /// answer or a log to reconstruct one from.
    private var hasOutput: Bool {
        guard let lastRun else { return false }
        return lastRun.resultText != nil || lastRun.outputFile != nil
    }

    private var handlers: TaskCardActions {
        TaskCardActions(
            edit: onEdit,
            copyPrompt: {
                onCopy()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            },
            openInTerminal: onOpenInTerminal,
            runWithClaude: onRunWithClaude,
            stop: onStop,
            viewOutput: onViewOutput,
            markComplete: onComplete,
            retry: onRetry,
            restore: onRestore,
            moveToTop: onMoveToTop,
            duplicate: onDuplicate,
            archive: onArchive,
            delete: onDelete
        )
    }
}

// MARK: - Ready

/// The card that has to answer "should I run this next?".
///
/// Everything on it is chosen for that decision: how long it will take, what it
/// is allowed to do, whether its directory is still there, and — if Tokenmax
/// will not start it unattended — exactly why not.
struct ReadyTaskCardView: View {
    let task: TokenmaxTask
    let autoRunBlock: QueueAutoRunDecision.SkipReason?
    let directoryExists: Bool
    let actions: TaskActionSet
    let handlers: TaskCardActions
    @Binding var copied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TaskStatusIndicator(status: .ready)
                TaskTitleText(task: task)
                Spacer(minLength: 8)
                TaskPriorityBadge(priority: task.priority)
            }

            TaskPromptPreview(task: task)

            TaskDirectoryLine(task: task, exists: directoryExists)

            TaskMetadataRow(items: runtimeItems)

            automationLine

            TaskCardActionsView(actions: actions, handlers: handlers, copied: $copied)
                .padding(.top, 1)
        }
        .taskCardBackground()
    }

    /// What it will cost in time and what it may touch — the facts that decide
    /// whether now is a good moment, rather than restating the provider and the
    /// project name that every card shares.
    private var runtimeItems: [String] {
        var items: [String] = []
        items.append(task.estimatedMinutes.map { "~\($0) min" } ?? "no estimate")
        items.append("\(task.maximumRuntimeMinutes) min limit")
        if task.provider == .codex {
            items.append(task.codex.sandbox.displayName)
        } else {
            items.append(task.autoRun.allowShellCommands
                ? "Shell access enabled"
                : (task.autoRun.allowFileChanges ? "Can change files" : "Read-only"))
        }
        return items
    }

    /// Shown per card rather than only as a global "nothing can run", so the
    /// user can see which of five queued tasks is the one holding things up.
    @ViewBuilder
    private var automationLine: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .accessibilityLabel(text)
    }

    private var icon: String {
        guard let autoRunBlock else { return "checkmark.seal" }
        return autoRunBlock == .notApprovedForAutomation ? "hand.raised" : "exclamationmark.circle"
    }

    /// "Manual only" is a setting, not a problem — it must not read as a warning
    /// next to a genuinely broken working directory.
    private var tint: Color {
        guard let autoRunBlock else { return .secondary }
        return autoRunBlock == .notApprovedForAutomation ? .secondary : .orange
    }

    private var text: String {
        switch autoRunBlock {
        case .none:
            "Auto-run approved"
        case .notApprovedForAutomation:
            "Manual only"
        case .workingDirectoryMissing:
            "Auto-run blocked · working directory missing"
        case .noRuntimeEstimate:
            "Auto-run blocked · no estimate"
        case .insufficientTime:
            "Auto-run waiting · not enough time before the reset"
        case .runtimeExceedsWindowBudget:
            "Auto-run waiting · longer than the remaining session budget"
        case let .some(reason):
            "Auto-run blocked · \(reason.explanation)"
        }
    }
}

// MARK: - Running

/// Deliberately not a ready card with a spinner bolted on.
///
/// While something is running there is exactly one useful question — what is it
/// doing — and exactly one useful action. The prompt preview and the automation
/// explanation are gone because neither helps now.
struct RunningTaskCardView: View {
    let task: TokenmaxTask
    let directoryExists: Bool
    let isRunningHere: Bool
    let progress: String?
    let lastRun: TaskRunRecord?
    let now: Date
    let actions: TaskActionSet
    let handlers: TaskCardActions
    @Binding var copied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TaskStatusIndicator(status: .running, isRunningHere: isRunningHere)
                TaskTitleText(task: task)
                Spacer(minLength: 8)
                Text(isRunningHere ? "Running" : "In a terminal")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            if isRunningHere {
                Text(progress ?? "Claude is working…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                // The user is driving this one; say so rather than implying
                // Tokenmax is watching a process it does not have.
                Text("Running in your terminal. Mark it complete when you are done.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TaskDirectoryLine(task: task, exists: directoryExists)

            TaskMetadataRow(items: metadata)

            TaskCardActionsView(actions: actions, handlers: handlers, copied: $copied)
                .padding(.top, 1)
        }
        .taskCardBackground(accent: Color.accentColor.opacity(0.35))
    }

    private var metadata: [String] {
        var items: [String] = []
        if let startedAt = task.startedAt {
            items.append("running \(RelativeTime.short(now.timeIntervalSince(startedAt)))")
        }
        if isRunningHere {
            items.append(lastRun?.model ?? task.selectedModel)
            items.append("\(task.maximumRuntimeMinutes) min limit")
        }
        return items
    }
}

// MARK: - Completed

/// History, not a queue entry. Compact by design — the point of the Completed
/// band is to scan it, and a screen of full-height cards cannot be scanned.
struct CompletedTaskRowView: View {
    let task: TokenmaxTask
    let lastRun: TaskRunRecord?
    let actions: TaskActionSet
    let handlers: TaskCardActions
    @Binding var copied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                TaskStatusIndicator(status: .completed)
                TaskTitleText(task: task, size: 12)
                Spacer(minLength: 8)
                TaskMetadataRow(items: outcome)
            }

            TaskPromptPreview(task: task, lineLimit: 1)

            TaskCardActionsView(actions: actions, handlers: handlers, copied: $copied)
                .padding(.top, 1)
        }
        .taskCardBackground(isCompact: true)
    }

    /// What it cost and when — the three facts worth keeping about a finished
    /// run. The automation explanation is deliberately absent: whether it
    /// *would* auto-run is no longer a question about this task.
    private var outcome: [String] {
        var items: [String] = []
        if let run = lastRun, let finishedAt = run.finishedAt {
            items.append(RelativeTime.short(finishedAt.timeIntervalSince(run.startedAt)))
        }
        if let cost = lastRun?.costUSD {
            items.append(String(format: "$%.2f", cost))
        }
        if let completedAt = task.completedAt {
            items.append(Self.formatter.string(from: completedAt))
        }
        return items
    }

    /// "Today at 14:42" for recent work, a date for anything older.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Needs attention

/// Distinguishable without colour: a warning glyph, a heavier border, and the
/// error stated as a sentence rather than as red text that a colour-blind user
/// would read as ordinary body copy.
struct NeedsAttentionTaskCardView: View {
    let task: TokenmaxTask
    let directoryExists: Bool
    let actions: TaskActionSet
    let handlers: TaskCardActions
    @Binding var copied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TaskStatusIndicator(status: .needsAttention)
                TaskTitleText(task: task)
                Spacer(minLength: 8)
                Text("Needs Attention")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Text(task.errorMessage ?? "This task did not finish.")
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            TaskDirectoryLine(task: task, exists: directoryExists)

            TaskCardActionsView(actions: actions, handlers: handlers, copied: $copied)
                .padding(.top, 1)
        }
        .taskCardBackground(accent: Color.orange.opacity(0.45))
    }
}

// MARK: - Archived

struct ArchivedTaskRowView: View {
    let task: TokenmaxTask
    let actions: TaskActionSet
    let handlers: TaskCardActions
    @Binding var copied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                TaskStatusIndicator(status: .archived)
                TaskTitleText(task: task, size: 12)
                Spacer(minLength: 8)
            }

            TaskPromptPreview(task: task, lineLimit: 1)

            TaskCardActionsView(actions: actions, handlers: handlers, copied: $copied)
                .padding(.top, 1)
        }
        .taskCardBackground(isCompact: true)
        .opacity(0.85)
    }
}
