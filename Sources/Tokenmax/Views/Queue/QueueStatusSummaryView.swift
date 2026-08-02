import SwiftUI

/// The queue's one-line state, plus the burn prompt when one applies.
///
/// Deliberately quiet: the counts are always there because they always mean
/// something, and the burn line only appears while the opportunity is real. A
/// banner that is permanently on screen stops being read, which is the same
/// reasoning the popover's opener and auto-run lines already follow.
struct QueueStatusSummaryView: View {
    let tasks: [TokenmaxTask]
    let burnOpportunity: BurnOpportunity?
    let highlight: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(QueueListModel.statusSummary(tasks))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if burnOpportunity != nil {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                    Text("Good time to use remaining session quota")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(highlight)
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: burnOpportunity != nil)
        .accessibilityElement(children: .combine)
    }
}
