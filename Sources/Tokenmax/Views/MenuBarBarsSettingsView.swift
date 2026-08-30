import SwiftUI

/// The bar half of the icon editor: how many bars, and which quota each one
/// draws. The dragging itself lives in `QuotaSlotEditor`, which the ring editor
/// shares.
struct MenuBarBarsSettingsView: View {
    @Binding var bars: MenuBarBars

    /// The quotas whose provider is switched on. A disabled provider's source
    /// must not appear in the tray, survive a drop, or be reachable by growing
    /// the bar count.
    var allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases

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

            QuotaSlotEditor(
                labels: (1...visible.count).map(String.init),
                sources: visible.sources,
                unused: visible.unused(allowed: allowed),
                onDrop: { index, source in
                    bars = visible.replacing(at: index, with: source, allowed: allowed)
                }
            )
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
}

/// The ring half. Two arcs per ring, outer then inner, and the same drag
/// semantics as the bars — a drop onto an occupied slot swaps rather than
/// discarding, so no gesture can lose an arc.
struct MenuBarRingsSettingsView: View {
    @Binding var rings: MenuBarRings

    var allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases

    private var visible: MenuBarRings { MenuBarRings(rings.sources, allowed: allowed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A second ring needs a second provider's two quotas. With one
            // provider on there is nothing to choose, so the control goes away
            // rather than offering a count normalization would undo.
            if allowed.count >= MenuBarRings.maximumCount {
                Picker("Rings", selection: ringCountBinding) {
                    Text("1 ring").tag(1)
                    Text("2 rings").tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            QuotaSlotEditor(
                labels: (0..<visible.count).map { $0 % 2 == 0 ? "\($0 / 2 + 1) out" : "\($0 / 2 + 1) in" },
                sources: visible.sources,
                unused: visible.unused(allowed: allowed),
                onDrop: { index, source in
                    rings = visible.replacing(at: index, with: source, allowed: allowed)
                }
            )
        }
    }

    private var ringCountBinding: Binding<Int> {
        Binding(
            get: { visible.ringCount },
            set: { rings = visible.resized(toRings: $0, allowed: allowed) }
        )
    }
}
