import SwiftUI

/// Active work above history, as two labelled segmented controls.
///
/// A source list would be the more conventional macOS answer, but it costs about
/// 160pt of width that this window does not have to spare — the task cards are
/// the content, and squeezing them to make room for five permanent rows would be
/// the wrong trade. Two labelled groups carry the same split.
///
/// The QUEUE group is listed first and given the heavier label because that is
/// the ordering the window is for: what can run, what is running, what is stuck.
struct QueueNavigationView: View {
    @Binding var filter: QueueFilter
    let tasks: [TokenmaxTask]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            group(.queue)
            group(.history)
            Spacer(minLength: 0)
        }
    }

    private func group(_ section: QueueSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.displayName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(section == .queue ? .secondary : .tertiary)
                .tracking(0.5)

            Picker("", selection: $filter) {
                ForEach(QueueFilter.cases(in: section)) { option in
                    // The count is always shown, including zero. A segment that
                    // changes width as its count appears and disappears is
                    // harder to hit and harder to read than one that does not,
                    // and "0" is itself the answer to "is anything stuck?".
                    Text("\(option.shortName) \(QueueListModel.count(tasks, option))")
                        .tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("\(section.displayName) filter")
        }
    }
}
