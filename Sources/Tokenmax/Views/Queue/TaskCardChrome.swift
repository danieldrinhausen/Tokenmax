import SwiftUI

/// The pieces every task card is built from.
///
/// Shared so the five states look like five treatments of one thing rather than
/// five unrelated rows, but kept as small independent views rather than one
/// configurable mega-card — the states differ in what they *say*, not just in
/// how they are decorated, and a single view with five modes would be harder to
/// read than five short ones.

// MARK: - Status indicator

/// The leading state marker.
///
/// Shape carries the meaning and colour reinforces it, never the other way
/// round: a filled ring, a spinner, a tick, and a warning triangle are all
/// distinguishable with no colour at all.
struct TaskStatusIndicator: View {
    let status: TaskStatus
    var isRunningHere = false

    var body: some View {
        Group {
            switch status {
            case .ready:
                Image(systemName: "circle")
            case .running:
                if isRunningHere {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "circle.dotted")
                }
            case .completed:
                Image(systemName: "checkmark.circle.fill")
            case .needsAttention:
                Image(systemName: "exclamationmark.triangle.fill")
            case .archived:
                Image(systemName: "archivebox.fill")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(tint)
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch status {
        case .ready: .secondary
        case .running: .accentColor
        case .completed: .green
        case .needsAttention: .orange
        case .archived: .secondary
        }
    }
}

// MARK: - Title

struct TaskTitleText: View {
    let task: TokenmaxTask
    var size: CGFloat = 13

    var body: some View {
        Text(task.title.isEmpty ? "Untitled task" : task.title)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            // The title is the one thing that must survive a narrow window, so
            // it is the last thing allowed to give up its space.
            .layoutPriority(2)
    }
}

/// Only shown when it is worth showing. "Medium" on every card is noise; a card
/// marked Urgent among six that are not is information.
struct TaskPriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        if priority == .high || priority == .urgent {
            Text(priority.displayName)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(tint.opacity(0.16), in: Capsule())
                .foregroundStyle(tint)
                .accessibilityLabel("\(priority.displayName) priority")
        }
    }

    private var tint: Color { priority == .urgent ? .red : .orange }
}

// MARK: - Prompt

struct TaskPromptPreview: View {
    let task: TokenmaxTask
    var lineLimit = 2

    var body: some View {
        Text(task.prompt)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Working directory

/// The working directory, shortened from the front so the project folder — the
/// part that identifies it — stays visible when the path does not fit. The full
/// path is always available as a tooltip.
struct TaskDirectoryLine: View {
    let task: TokenmaxTask
    let exists: Bool

    var body: some View {
        if let directory = task.workingDirectory, !directory.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: exists ? "folder" : "folder.badge.questionmark")
                    .font(.system(size: 9))
                Text(directory)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                if !exists {
                    Text("not found")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(exists ? Color.secondary : Color.orange)
            .help(task.expandedWorkingDirectory?.path ?? directory)
            .accessibilityLabel(
                exists
                    ? "Working directory \(directory)"
                    : "Working directory \(directory), not found"
            )
        }
    }
}

// MARK: - Metadata

/// A single dot-separated line of short facts. Empty entries are dropped so
/// callers can build the list conditionally without leaving stray separators.
struct TaskMetadataRow: View {
    let items: [String]
    var tint: Color = .secondary

    var body: some View {
        let visible = items.filter { !$0.isEmpty }
        if !visible.isEmpty {
            Text(visible.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

// MARK: - Card background

/// The shared card shell.
///
/// History rows get a lighter treatment than active ones — less fill, no border
/// — so that a screen of completed tasks reads as a record rather than as a
/// queue of things still demanding attention.
struct TaskCardBackground: ViewModifier {
    var accent: Color?
    var isCompact = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, isCompact ? 8 : 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(isCompact ? 0.04 : 0.07),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        accent ?? Color.secondary.opacity(isCompact ? 0.08 : 0.14),
                        lineWidth: accent == nil ? 1 : 1.5
                    )
            )
    }
}

extension View {
    func taskCardBackground(accent: Color? = nil, isCompact: Bool = false) -> some View {
        modifier(TaskCardBackground(accent: accent, isCompact: isCompact))
    }
}
