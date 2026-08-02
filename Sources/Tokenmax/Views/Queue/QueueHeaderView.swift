import SwiftUI

/// The operational header: what quota is left, what the queue looks like, and
/// the three things worth doing from here.
///
/// The title is "Queue" rather than "Tokenmax" because the window is already
/// titled "Tokenmax Queue" — repeating the app name inside its own window spends
/// the most prominent line in the view saying something the title bar just said.
struct QueueHeaderView: View {
    let state: UsageState
    let isStale: Bool
    let now: Date
    let tasks: [TokenmaxTask]
    let burnOpportunity: BurnOpportunity?
    let highlight: Color
    let isRefreshing: Bool

    /// Why nothing can run right now, for the Run Next tooltip. Read from the
    /// coordinator's last published decision — never recomputed here, because
    /// a fresh verdict costs a subprocess and a settings-file read and this view
    /// redraws every second.
    let runNextBlock: QueueAutoRunDecision.SkipReason?
    let canRunNext: Bool

    var onNewTask: () -> Void
    var onRunNext: () -> Void
    var onRefresh: () -> Void
    var onOpenTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Queue")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Claude Code usage and queued work")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                actions
            }

            QueueQuotaSummaryView(
                state: state,
                isStale: isStale,
                now: now,
                onRefresh: onRefresh,
                onOpenTerminal: onOpenTerminal
            )

            QueueStatusSummaryView(
                tasks: tasks,
                burnOpportunity: burnOpportunity,
                highlight: highlight
            )
        }
        .padding(16)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            .help(isRefreshing ? "Refreshing usage…" : "Refresh usage")
            .accessibilityLabel("Refresh usage")

            // Never bypasses a safety gate: this calls the coordinator's
            // `runNextEligibleNow`, which re-checks the working directory, the
            // CLI, the subscription, and the API-key settings before anything
            // starts.
            Button("Run Next", action: onRunNext)
                .disabled(!canRunNext)
                .help(runNextHelp)
                .accessibilityLabel("Run the next eligible task")
                .accessibilityHint(runNextHelp)

            Button(action: onNewTask) {
                Label("New Task", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("New task")
        }
    }

    /// Explains a disabled button rather than leaving the user to guess. The
    /// reasons come from the same enum the auto-runner logs, so the tooltip and
    /// the log cannot disagree.
    private var runNextHelp: String {
        guard let runNextBlock else {
            return canRunNext
                ? "Run the next task that is ready to go."
                : "Nothing can run right now."
        }
        return runNextBlock.explanation
    }
}
