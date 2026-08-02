import AppKit
import SwiftUI

/// The colour of the menubar "spend it now" highlight.
///
/// Stored as plain sRGB components rather than an archived `NSColor`, so
/// `settings.json` stays readable and hand-editable like every other value in
/// it. sRGB specifically, because that is the space `ColorPicker` hands back —
/// storing in one space and picking in another would drift the colour a little
/// on every round trip through the settings pane.
///
/// Alpha is deliberately absent. A translucent highlight reads as a rendering
/// fault rather than a choice, and the glow already supplies the only softness
/// the icon wants.
struct HighlightColor: Codable, Sendable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// Lenient and clamping, for the same reason as `AppSettings.init(from:)`:
    /// a missing key or a hand-edited value out of range must not take the whole
    /// settings file down with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HighlightColor.default
        self.init(
            red: try container.decodeIfPresent(Double.self, forKey: .red) ?? fallback.red,
            green: try container.decodeIfPresent(Double.self, forKey: .green) ?? fallback.green,
            blue: try container.decodeIfPresent(Double.self, forKey: .blue) ?? fallback.blue
        )
    }

    /// NaN is special-cased because it has no ordering: every comparison
    /// against it is false, so a plain `max(0, min(1, .nan))` returns 1 and a
    /// garbage channel silently becomes a fully saturated one. The infinities
    /// need no such help — they clamp to the end they point at.
    private static func clamped(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return max(0, min(1, value))
    }

    // MARK: - Bridging

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    /// Round-trips a picked colour back into storage. `usingColorSpace` returns
    /// nil for pattern and catalog colours, which the picker cannot produce but
    /// which a future caller might — falling back to the default beats crashing.
    init(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            self = .default
            return
        }
        self.init(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent)
        )
    }

    // MARK: - Legibility

    /// WCAG relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The menu bar is not a surface the app controls: its contrast follows the
    /// *wallpaper*, so the same icon has to survive on near-white and on
    /// near-black. A colour that only works against one of them is a colour the
    /// user will lose track of half the time.
    ///
    /// 1.6 rather than a WCAG text threshold — this is a 5pt solid bar, not body
    /// copy, and every built-in preset would fail a stricter bar (the default
    /// green reaches only 1.89 against white).
    static let minimumContrastRatio: Double = 1.6

    var isLegibleOnAnyMenuBar: Bool {
        let luminance = relativeLuminance
        let againstBlack = (luminance + 0.05) / 0.05
        let againstWhite = 1.05 / (luminance + 0.05)
        return min(againstBlack, againstWhite) >= Self.minimumContrastRatio
    }

    // MARK: - Presets

    /// The green Tokenmax has always used. Kept as the default so upgrading
    /// changes nothing for anyone who never opens the setting.
    static let `default` = HighlightColor(red: 0.16, green: 0.85, blue: 0.35)

    /// Every preset clears `minimumContrastRatio` on both a light and a dark
    /// menu bar, so the legibility warning is reachable only from a custom pick.
    static let presets: [HighlightPreset] = [
        HighlightPreset(id: "green", name: "Green", color: .default),
        HighlightPreset(id: "teal", name: "Teal", color: HighlightColor(red: 0.10, green: 0.78, blue: 0.75)),
        HighlightPreset(id: "blue", name: "Blue", color: HighlightColor(red: 0.20, green: 0.60, blue: 1.00)),
        HighlightPreset(id: "purple", name: "Purple", color: HighlightColor(red: 0.68, green: 0.42, blue: 0.98)),
        HighlightPreset(id: "pink", name: "Pink", color: HighlightColor(red: 1.00, green: 0.35, blue: 0.62)),
        HighlightPreset(id: "orange", name: "Orange", color: HighlightColor(red: 1.00, green: 0.58, blue: 0.10)),
    ]
}

struct HighlightPreset: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let color: HighlightColor
}
