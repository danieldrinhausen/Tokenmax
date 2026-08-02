import SwiftUI

/// The countdown, the live run, and the paused state — the three things that
/// need to be visible the moment the queue window is opened.
///
/// Lifted out of `QueueView` unchanged in behaviour. It still shows nothing when
/// there is nothing to act on: routine waiting is not worth a permanent banner.
struct AutoRunStatusBannerView: View {
    let pendingRun: PendingAutoRun?
    let activeRun: TaskRunRecord?
    let progressText: String?
    let isPausedAfterFailure: Bool
    let awaitingFreshUsage: Bool
    let now: Date

    var onStartNow: () -> Void
    var onCancelPending: () -> Void
    var onStop: () -> Void
    var onResume: () -> Void

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.2), value: pendingRun?.taskID)
            .animation(.easeInOut(duration: 0.2), value: activeRun?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let pending = pendingRun {
            let seconds = pending.secondsRemaining(now: now)
            banner(icon: "timer", tint: .orange) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-run starts “\(pending.taskTitle)” in \(QueueListModel.pluralized(seconds, "second"))")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Tokenmax will run this task with Claude Code.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                HStack(spacing: 6) {
                    Button("Start Now", action: onStartNow)
                    Button("Cancel", action: onCancelPending)
                }
                .font(.system(size: 11))
            }
        } else if let run = activeRun {
            banner(icon: "play.circle", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running “\(run.taskTitle)”")
                        .font(.system(size: 11, weight: .semibold))
                    Text(progressText ?? "Working…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } trailing: {
                Button("Stop", action: onStop)
                    .font(.system(size: 11))
            }
        } else if isPausedAfterFailure {
            banner(icon: "exclamationmark.triangle", tint: .orange) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Queue paused after a failure")
                        .font(.system(size: 11, weight: .semibold))
                    Text("No further task will start automatically this session.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Resume", action: onResume)
                    .font(.system(size: 11))
            }
        } else if awaitingFreshUsage {
            banner(icon: "clock.arrow.circlepath", tint: .secondary) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-run is waiting for fresh quota data")
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
        .accessibilityElement(children: .contain)
    }
}
