import SwiftUI
import UniformTypeIdentifiers

/// Assigns a quota to each slot of the menubar icon by dragging.
///
/// The slots are fixed and the *contents* move, rather than a reorderable list:
/// a slot is a position on screen, so "which quota is the top bar" — or "which
/// quota is the outer arc of the left ring" — is the actual question, and a list
/// that can be emptied or duplicated would let the user build an icon that
/// cannot be drawn.
///
/// Shared by the bar and ring editors. Both ask the same thing of the same four
/// quotas and differ only in what the positions are called, so the drag
/// plumbing lives here and each editor keeps just its own count control and its
/// own model.
struct QuotaSlotEditor: View {
    /// What each position is called, in drawing order. Its count is the slot
    /// count — `sources` is expected to match.
    let labels: [String]
    let sources: [MenuBarQuotaSource]
    /// The quotas not currently placed, for the tray. Empty hides it.
    let unused: [MenuBarQuotaSource]
    /// What a drop means. The model decides whether it is a swap, a
    /// replacement, or a refusal.
    let onDrop: (Int, MenuBarQuotaSource) -> Void

    /// Which slot is currently under a drag, so the drop target is visible
    /// before the mouse is released.
    @State private var targetedSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                slot(index: index, source: source)
            }

            if !unused.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Drag onto a slot to swap")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(unused) { source in
                        chip(source, isPlaced: false)
                            .draggable(source.rawValue)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func slot(index: Int, source: MenuBarQuotaSource) -> some View {
        HStack(spacing: 8) {
            Text(labels.indices.contains(index) ? labels[index] : "")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: labelWidth, alignment: .trailing)
            chip(source, isPlaced: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    targetedSlot == index ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .draggable(source.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dropped = MenuBarQuotaSource(rawValue: raw) else { return false }
            onDrop(index, dropped)
            return true
        } isTargeted: { targetedSlot = $0 ? index : nil }
    }

    /// Sized to the longest label so the chips line up in a column. Ring labels
    /// are words where bar labels are single digits, and a per-row intrinsic
    /// width would leave the chips ragged.
    private var labelWidth: CGFloat {
        labels.contains { $0.count > 2 } ? 40 : 12
    }

    private func chip(_ source: MenuBarQuotaSource, isPlaced: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(source.displayName)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.secondary.opacity(isPlaced ? 0.15 : 0.07),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .opacity(isPlaced ? 1 : 0.7)
    }
}
