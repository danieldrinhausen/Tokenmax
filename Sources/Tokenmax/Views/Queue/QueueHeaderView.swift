import SwiftUI

/// The operational header: what quota is left, what the queue looks like, and
/// the three things worth doing from here.
///
/// The title is "Queue" rather than "Tokenmax" because the window is already
/// titled "Tokenmax Queue" — repeating the app name inside its own window spends
/// the most prominent line in the view saying something the title bar just said.
struct QueueHeaderView: View {
    /// One provider's quota, ready to render. Assembled by the caller so this
    /// view needs no coordinator of its own.
    struct ProviderQuota: Identifiable {
        let provider: TokenmaxProvider
        let state: UsageState
        let isStale: Bool
        let onRefresh: () -> Void

        var id: TokenmaxProvider { provider }
    }

    let quotas: [ProviderQuota]
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
                    Text("Provider usage and queued work")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                actions
            }

            providerQuotas

            QueueStatusSummaryView(
                tasks: tasks,
                burnOpportunity: burnOpportunity,
                highlight: highlight
            )
        }
        .padding(16)
    }

    /// Providers side by side when they fit, stacked when they do not.
    ///
    /// `ViewThatFits` rather than a fixed two-column grid for the same reason
    /// `QueueView.controls` uses it: two columns of quota want about 600pt, the
    /// window can be narrower, and an `HStack` that overflows does not compress
    /// — it renders off the leading edge and drags the header's alignment with it.
    @ViewBuilder
    private var providerQuotas: some View {
        if quotas.count <= 1 {
            // A single provider gets the full width and no heading: there is
            // nothing to tell it apart from.
            ForEach(quotas) { quota in
                summary(quota, isCompact: false)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(quotas) { quota in
                        labelled(quota, isCompact: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(quotas) { quota in
                        labelled(quota, isCompact: false)
                    }
                }
            }
        }
    }

    private func labelled(_ quota: ProviderQuota, isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(quota.provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            summary(quota, isCompact: isCompact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ quota: ProviderQuota, isCompact: Bool) -> some View {
        QueueQuotaSummaryView(
            state: quota.state,
            isStale: quota.isStale,
            now: now,
            provider: quota.provider,
            isCompact: isCompact,
            onRefresh: quota.onRefresh,
            onOpenTerminal: onOpenTerminal
        )
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
