import SwiftUI

/// What the list says when it has nothing to show.
///
/// Each state names the reason it is empty rather than sharing one "no tasks"
/// message, because the reasons are genuinely different: an empty Needs
/// Attention band is good news, an empty Ready band is an invitation, and an
/// empty search result is a dead end the user needs a way out of.
struct QueueEmptyStateView: View {
    let filter: QueueFilter
    let query: String
    /// Nothing read, nothing queued — so this is a first launch, and the space
    /// is better spent explaining what Tokenmax does than repeating "no tasks".
    let isFirstRun: Bool

    var onNewTask: () -> Void
    var onClearSearch: () -> Void
    var onOpenTerminal: () -> Void
    var onRefresh: () -> Void

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()

            if isFirstRun, !isSearching {
                FirstRunGuidanceView(onNewTask: onNewTask, onOpenTerminal: onOpenTerminal, onRefresh: onRefresh)
            } else {
                standardEmptyState
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var standardEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            action
                .padding(.top, 3)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        if isSearching { return "magnifyingglass" }
        switch filter {
        case .ready: return "tray"
        case .running: return "pause.circle"
        case .needsAttention: return "checkmark.circle"
        case .completed: return "clock.arrow.circlepath"
        case .archived: return "archivebox"
        }
    }

    private var title: String {
        if isSearching { return "No matching tasks" }
        switch filter {
        case .ready: return "No tasks ready"
        case .running: return "Nothing is running"
        case .needsAttention: return "Everything looks good"
        case .completed: return "No completed tasks yet"
        case .archived: return "Nothing archived"
        }
    }

    private var message: String {
        if isSearching {
            return "Nothing in \(filter.displayName) matches “\(query)”. Try a different search term or clear the search."
        }
        switch filter {
        case .ready:
            return "Add prompts during the day so unused quota has somewhere to go."
        case .running:
            return "Start a ready task or enable queue automation in Settings."
        case .needsAttention:
            return "No tasks currently need attention."
        case .completed:
            return "Completed runs will appear here."
        case .archived:
            return "Archived tasks are kept out of the queue but never deleted."
        }
    }

    @ViewBuilder
    private var action: some View {
        if isSearching {
            Button("Clear Search", action: onClearSearch)
        } else if filter == .ready {
            Button("New Task", action: onNewTask)
        }
    }
}

/// Shown on a first launch, in place of an empty Ready list.
///
/// A panel rather than a wizard: Tokenmax is a menubar utility, and putting a
/// multi-step setup flow in front of someone who has just installed one would be
/// out of keeping with everything else about it. The two facts that matter most
/// — automation is off, and file changes are a separate grant — are stated here
/// so nobody has to discover them from a task that edited something.
private struct FirstRunGuidanceView: View {
    var onNewTask: () -> Void
    var onOpenTerminal: () -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Tokenmax")
                    .font(.system(size: 14, weight: .semibold))
                Text("Tokenmax watches how much Claude Code and Codex quota you have left, and gives leftover quota somewhere to go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                point("chart.bar", "Tokenmax reads your Claude Code and Codex usage.", detail: nil)
                point(
                    "terminal",
                    "The agent must be installed and signed in.",
                    detail: "Run claude, or codex, once in a terminal if you have not already."
                )
                point("tray", "The queue is optional.", detail: "Tokenmax works as a usage meter on its own.")
                point(
                    "hand.raised",
                    "Automatic execution is off by default.",
                    detail: "Nothing runs unattended until you turn it on and approve a task."
                )
                point(
                    "pencil",
                    "Automatic runs can change files only when you approve it.",
                    detail: "That is a per-task permission, off by default."
                )
                point(
                    "exclamationmark.triangle",
                    "Shell access is a separate, higher-risk permission.",
                    detail: "Shell commands are not limited to the working directory."
                )
            }

            HStack(spacing: 8) {
                Button("New Task", action: onNewTask)
                Button("Open Terminal", action: onOpenTerminal)
                Button("Refresh Usage", action: onRefresh)
            }
            .font(.system(size: 11))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func point(_ icon: String, _ text: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
