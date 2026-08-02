import AppKit
import SwiftUI
import Testing

@testable import Tokenmax

@Suite("Highlight colour")
struct HighlightColorTests {
    /// The one thing an upgrade must not do is repaint a menu bar nobody asked
    /// to have repainted.
    @Test("The default is the green the icon has always used")
    func defaultMatchesTheOriginalGreen() {
        #expect(HighlightColor.default == HighlightColor(red: 0.16, green: 0.85, blue: 0.35))
        #expect(MenuBarIconRenderer.readyColor == HighlightColor.default.nsColor)
    }

    @Test("Components are clamped on the way in")
    func componentsAreClamped() {
        let clamped = HighlightColor(red: 2, green: -1, blue: 0.4)

        #expect(clamped.red == 1)
        #expect(clamped.green == 0)
        #expect(clamped.blue == 0.4)
    }

    @Test("A non-finite component cannot poison the colour")
    func nonFiniteComponentsAreRejected() {
        let broken = HighlightColor(red: .nan, green: .infinity, blue: 0.5)

        #expect(broken.red == 0)
        #expect(broken.green == 1)
        #expect(broken.blue == 0.5)
    }

    /// Storage and the picker have to agree, or the colour drifts a little every
    /// time the user opens Settings and closes it again.
    @Test("A colour survives a trip through SwiftUI and back")
    func roundTripsThroughSwiftUIColor() {
        for preset in HighlightColor.presets {
            let returned = HighlightColor(preset.color.color)

            #expect(abs(returned.red - preset.color.red) < 0.001, "\(preset.name) red")
            #expect(abs(returned.green - preset.color.green) < 0.001, "\(preset.name) green")
            #expect(abs(returned.blue - preset.color.blue) < 0.001, "\(preset.name) blue")
        }
    }

    /// The presets are the safe menu of choices — if one of them tripped the
    /// warning, the warning would stop meaning anything.
    @Test("Every preset is legible on both a light and a dark menu bar")
    func presetsAreLegible() {
        for preset in HighlightColor.presets {
            #expect(preset.color.isLegibleOnAnyMenuBar, "\(preset.name) is not legible")
        }
    }

    @Test("Preset identifiers are unique")
    func presetIdentifiersAreUnique() {
        let ids = Set(HighlightColor.presets.map(\.id))
        #expect(ids.count == HighlightColor.presets.count)
    }

    /// Both failure modes the warning exists for: something that vanishes on a
    /// dark menu bar, and something that vanishes on a light one.
    @Test("Near-black and near-white are flagged as illegible")
    func extremesAreFlagged() {
        #expect(!HighlightColor(red: 0.03, green: 0.03, blue: 0.06).isLegibleOnAnyMenuBar)
        #expect(!HighlightColor(red: 0.97, green: 0.97, blue: 0.92).isLegibleOnAnyMenuBar)
    }

    @Test("A mid-tone is legible against either extreme")
    func midTonesAreLegible() {
        #expect(HighlightColor(red: 0.5, green: 0.5, blue: 0.5).isLegibleOnAnyMenuBar)
    }
}
