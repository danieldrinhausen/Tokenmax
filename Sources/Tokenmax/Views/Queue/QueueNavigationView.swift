import SwiftUI

/// Active work above history, as two labelled tab groups.
///
/// A source list would be the more conventional macOS answer, but it costs about
/// 160pt of width that this window does not have to spare — the task cards are
/// the content, and squeezing them to make room for five permanent rows would be
/// the wrong trade. Two labelled groups carry the same split.
///
/// The QUEUE group is listed first and given the heavier label because that is
/// the ordering the window is for: what can run, what is running, what is stuck.
///
/// These are hand-rolled tabs rather than a `.segmented` Picker because the
/// count belongs in a badge, and a segmented Picker bridges to
/// `NSSegmentedControl`, whose segments take a plain string title — a nested
/// view gets flattened and per-segment styling is dropped. The cost of leaving
/// the native control is the selected/hover state and the accessibility traits
/// below, which the Picker used to supply for free.
struct QueueNavigationView: View {
    @Binding var filter: QueueFilter
    let tasks: [TokenmaxTask]

    @State private var hovered: QueueFilter?

    var body: some View {
        // Counted once per redraw and handed down, rather than per tab. This
        // view is inside a header that redraws every second, and the old call
        // walked the whole task list once for each of the five segments.
        let counts = QueueListModel.counts(tasks)

        return HStack(alignment: .center, spacing: 16) {
            group(.queue, counts: counts)
            group(.history, counts: counts)
            Spacer(minLength: 0)
        }
    }

    private func group(_ section: QueueSection, counts: [TaskStatus: Int]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.displayName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(section == .queue ? .secondary : .tertiary)
                .tracking(0.5)

            HStack(spacing: 2) {
                ForEach(QueueFilter.cases(in: section)) { option in
                    tab(option, count: counts[option.status] ?? 0)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(section.displayName) filter")
        }
    }

    private func tab(_ option: QueueFilter, count: Int) -> some View {
        let isSelected = filter == option

        return Button {
            filter = option
        } label: {
            HStack(spacing: 5) {
                Text(option.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                badge(count, isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tabBackground(option, isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? option : (hovered == option ? nil : hovered)
        }
        .accessibilityLabel("\(option.shortName), \(count) \(count == 1 ? "task" : "tasks")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func tabBackground(_ option: QueueFilter, isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
        } else if hovered == option {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
        }
    }

    /// The count, in its own chip.
    ///
    /// Zero is still rendered, for the reason the segmented control rendered it:
    /// a tab that changes width as its count appears and disappears is harder to
    /// hit and harder to read than one that does not, and "0" is itself the
    /// answer to "is anything stuck?". It is dimmed rather than hidden so the
    /// tabs with work in them win the glance. `monospacedDigit` keeps the chip
    /// from twitching as counts tick between 9 and 10.
    private func badge(_ count: Int, isSelected: Bool) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(badgeForeground(count, isSelected: isSelected))
            .frame(minWidth: 8)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeFill(count, isSelected: isSelected), in: Capsule())
    }

    private func badgeForeground(_ count: Int, isSelected: Bool) -> Color {
        if isSelected {
            return .white.opacity(count == 0 ? 0.55 : 1)
        }
        return .primary.opacity(count == 0 ? 0.35 : 0.65)
    }

    private func badgeFill(_ count: Int, isSelected: Bool) -> Color {
        if isSelected {
            return .white.opacity(count == 0 ? 0.14 : 0.24)
        }
        return .primary.opacity(count == 0 ? 0.05 : 0.09)
    }
}
