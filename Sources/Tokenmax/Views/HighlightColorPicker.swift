import SwiftUI

/// Preset swatches plus a system colour well.
///
/// The presets are there because they are all known to survive both a light and
/// a dark menu bar; the well is there because a fixed palette cannot match
/// someone's existing menu bar, and refusing the choice would be the wrong kind
/// of protection. The legibility warning next to it covers the gap.
struct HighlightColorPicker: View {
    @Binding var color: HighlightColor

    var body: some View {
        LabeledContent("Colour") {
            HStack(spacing: 7) {
                ForEach(HighlightColor.presets) { preset in
                    swatch(preset)
                }

                ColorPicker(
                    "Custom highlight colour",
                    selection: Binding(
                        get: { color.color },
                        set: { color = HighlightColor($0) }
                    ),
                    // Alpha is not stored; offering it would silently discard
                    // half of what the user picked.
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }

    private func swatch(_ preset: HighlightPreset) -> some View {
        let isSelected = preset.color == color

        return Button {
            color = preset.color
        } label: {
            Circle()
                .fill(preset.color.color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(isSelected ? 0.85 : 0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}


/// The same swatch row, but the colour may be absent.
///
/// "Neutral" is a real choice rather than a missing one: it is what keeps the
/// icon a template image, tinted by macOS to whatever the menu bar currently
/// is. Offering it as the first swatch rather than as a checkbox beside the
/// picker is what makes that legible — it sits in the row of colours because it
/// is one of the options, and it is first because it is the default.
struct OptionalHighlightColorPicker: View {
    let label: String
    @Binding var color: HighlightColor?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 7) {
                neutralSwatch

                ForEach(HighlightColor.presets) { preset in
                    swatch(preset)
                }

                ColorPicker(
                    "Custom colour",
                    selection: Binding(
                        get: { (color ?? .default).color },
                        set: { color = HighlightColor($0) }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }

    private var neutralSwatch: some View {
        Button { color = nil } label: {
            Circle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: "circle.slash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(color == nil ? 0.85 : 0.15),
                        lineWidth: color == nil ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help("Neutral — the icon stays a template and matches the menu bar")
        .accessibilityLabel("Neutral")
        .accessibilityAddTraits(color == nil ? [.isButton, .isSelected] : .isButton)
    }

    private func swatch(_ preset: HighlightPreset) -> some View {
        let isSelected = color == preset.color

        return Button { color = preset.color } label: {
            Circle()
                .fill(preset.color.color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(isSelected ? 0.85 : 0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
