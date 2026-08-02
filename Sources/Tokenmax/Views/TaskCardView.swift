import SwiftUI

struct TaskCardView: View {
    let task: TokenmaxTask

    /// Why this task cannot be run automatically right now, or nil if it can.
    var autoRunBlock: QueueAutoRunDecision.SkipReason?
    /// Live progress while Tokenmax is running *this* task.
    var runProgress: String?
    var lastRun: TaskRunRecord?

    var onEdit: () -> Void
    var onCopy: () -> Void
    var onRun: () -> Void
    var onRunWithClaude: () -> Void
    var onStop: () -> Void
    var onViewOutput: () -> Void
    var onComplete: () -> Void
    var onRetry: () -> Void
    var onMoveToTop: () -> Void
    var onDuplicate: () -> Void
    var onArchive: () -> Void
    var onDelete: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                statusBadge
            }

            Text(metaLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let directory = task.workingDirectory, !directory.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: task.workingDirectoryExists ? "folder" : "folder.badge.questionmark")
                        .font(.system(size: 9))
                    Text(directory)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(task.workingDirectoryExists ? .secondary : Color.orange)
            }

            autoRunLine

            Text(task.prompt)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let runProgress {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(runProgress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let errorMessage = task.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("Edit", action: onEdit)
                Button(copied ? "Copied" : "Copy Prompt") {
                    onCopy()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }

                switch task.status {
                case .ready:
                    Button("Run with Claude", action: onRunWithClaude)
                case .running:
                    if runProgress != nil {
                        Button("Stop", action: onStop)
                    } else {
                        Button("Mark Complete", action: onComplete)
                    }
                case .needsAttention:
                    Button("Retry", action: onRetry)
                case .completed, .archived:
                    Button("Retry", action: onRetry)
                }

                // The first thing anyone wants after a run is what it said, so
                // it is a button rather than something to find in a menu.
                if hasOutput {
                    Button("View Result", action: onViewOutput)
                }

                Spacer()

                Menu {
                    // The 0.1 behaviour, kept and renamed: copy the prompt and
                    // open a terminal so the user drives the session themselves.
                    Button("Open in Terminal", action: onRun)
                    Divider()
                    Button("Move to Top", action: onMoveToTop)
                    Button("Duplicate", action: onDuplicate)
                    Divider()
                    Button("Archive", action: onArchive)
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.system(size: 11))
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    /// True once a run has produced something worth reading — either a stored
    /// answer or a log to reconstruct one from.
    private var hasOutput: Bool {
        guard let lastRun else { return false }
        return lastRun.resultText != nil || lastRun.outputFile != nil
    }

    /// Whether Tokenmax could run this task unattended, and if not, why.
    ///
    /// Shown per card rather than only as a global "no eligible task", so the
    /// user can see which of five queued tasks is the one holding things up.
    @ViewBuilder
    private var autoRunLine: some View {
        if task.status == .ready {
            HStack(spacing: 4) {
                Image(systemName: autoRunIcon)
                    .font(.system(size: 9))
                Text(autoRunText)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(autoRunColor)
        }
    }

    private var autoRunIcon: String {
        guard let autoRunBlock else { return "play.circle" }
        return autoRunBlock == .notApprovedForAutomation ? "hand.raised" : "exclamationmark.circle"
    }

    private var autoRunColor: Color {
        guard let autoRunBlock else { return .secondary }
        // "Manual only" is a setting, not a problem — it should not read as a
        // warning next to a genuinely broken working directory.
        return autoRunBlock == .notApprovedForAutomation ? .secondary : .orange
    }

    private var autoRunText: String {
        switch autoRunBlock {
        case .none:
            let estimate = task.estimatedMinutes.map { "~\($0) min" } ?? "no estimate"
            return "Auto-run ready · \(estimate) · limit \(task.autoRun.maximumRuntimeMinutes) min"
        case .notApprovedForAutomation:
            return "Manual only"
        case .workingDirectoryMissing:
            return "Auto-run blocked · working directory missing"
        case .noRuntimeEstimate:
            return "Auto-run blocked · no estimate"
        case .insufficientTime:
            return "Auto-run waiting · not enough time before the reset"
        case .runtimeExceedsWindowBudget:
            return "Auto-run waiting · longer than the remaining session budget"
        case let .some(reason):
            return "Auto-run blocked · \(reason.explanation)"
        }
    }

    private var metaLine: String {
        var parts = [task.priority.displayName, "Claude"]
        if let project = task.projectName, !project.isEmpty { parts.append(project) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if task.status != .ready {
            Text(task.status.displayName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        switch task.status {
        case .ready: .secondary
        case .running: .blue
        case .completed: .green
        case .needsAttention: .red
        case .archived: .secondary
        }
    }
}
