import SwiftUI
import UniformTypeIdentifiers

/// Assigns a quota to each bar of the menubar icon by dragging.
///
/// The slots are fixed and the *contents* move, rather than a reorderable list:
/// a bar is a position on screen, so "which quota is the top bar" is the actual
/// question, and a list that can be emptied or duplicated would let the user
/// build an icon that cannot be drawn.
struct MenuBarBarsSettingsView: View {
    @Binding var bars: MenuBarBars

    /// The quotas whose provider is switched on. A disabled provider's source
    /// must not appear in the tray, survive a drop, or be reachable by growing
    /// the bar count.
    var allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases

    /// Which slot is currently under a drag, so the drop target is visible
    /// before the mouse is released.
    @State private var targetedSlot: Int?

    /// The layout as drawn, which is not necessarily the layout as stored: a
    /// disabled provider keeps its slot in `bars` so re-enabling restores it.
    private var visible: MenuBarBars { MenuBarBars(bars.sources, allowed: allowed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One enabled quota can only be one bar, so the choice disappears
            // rather than offering a count that normalization would undo.
            if allowed.count >= MenuBarBars.minimumCount {
                Picker("Bars", selection: barCountBinding) {
                    Text("2 bars").tag(2)
                    if allowed.count >= 3 { Text("3 bars").tag(3) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(visible.sources.enumerated()), id: \.offset) { index, source in
                    slot(index: index, source: source)
                }
            }

            if !visible.unused(allowed: allowed).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Drag onto a bar to swap")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(visible.unused(allowed: allowed)) { source in
                        chip(source, isPlaced: false)
                            .draggable(source.rawValue)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// Editing the count through the layout's own `resized(to:)` keeps the
    /// two-or-three invariant with the model instead of the view.
    private var barCountBinding: Binding<Int> {
        Binding(
            get: { visible.count },
            set: { bars = visible.resized(to: $0, allowed: allowed) }
        )
    }

    private func slot(index: Int, source: MenuBarQuotaSource) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .trailing)
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
            bars = visible.replacing(at: index, with: dropped, allowed: allowed)
            return true
        } isTargeted: { targetedSlot = $0 ? index : nil }
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
