import AppKit
import Foundation
import Testing

@testable import Tokenmax

@Suite("Menubar ring layout")
struct MenuBarRingsTests {
    /// A session runs inside a week, so the enclosing arc is the week. Getting
    /// this backwards would draw the nesting the wrong way round.
    @Test("The default rings put each provider's week outside its session")
    func defaultLayout() {
        #expect(MenuBarRings.default.sources == [.claudeWeekly, .claudeSession, .codexWeekly, .codexSession])
        #expect(MenuBarRings.default.ringCount == 2)

        let rings = MenuBarRings.default.rings
        #expect(rings.map(\.outer) == [.claudeWeekly, .codexWeekly])
        #expect(rings.map(\.inner) == [.claudeSession, .codexSession])
    }

    /// A repeat would draw the same number twice and waste an arc.
    @Test("Duplicates are collapsed")
    func duplicatesCollapse() {
        let rings = MenuBarRings([.claudeWeekly, .claudeWeekly, .codexWeekly, .codexSession])
        #expect(rings.sources == [.claudeWeekly, .codexWeekly, .codexSession, .claudeSession])
    }

    /// Below one ring there is no icon to draw.
    @Test("A too-short layout is padded, not left empty")
    func shortLayoutIsPadded() {
        #expect(MenuBarRings([]).ringCount == 1)
        #expect(MenuBarRings([.codexSession]).ringCount == 1)
        #expect(MenuBarRings([.codexSession]).sources.first == .codexSession)
    }

    /// Half a ring has no drawing. A hand-edited `settings.json` that lists
    /// three sources gets a fourth rather than losing the third — padding
    /// invents a slot the user can re-assign, truncating discards a choice
    /// they already made.
    @Test("An odd layout is filled up to a whole ring, not cut down")
    func oddLayoutIsFilled() {
        let rings = MenuBarRings([.claudeWeekly, .claudeSession, .codexWeekly])
        #expect(rings.sources.count == 4)
        #expect(rings.ringCount == 2)
        #expect(rings.sources.prefix(3) == [.claudeWeekly, .claudeSession, .codexWeekly])
    }

    @Test("Two rings are the ceiling")
    func twoRingsIsTheCeiling() {
        #expect(MenuBarRings(MenuBarQuotaSource.allCases).ringCount == 2)
        #expect(MenuBarRings(MenuBarQuotaSource.allCases).count == MenuBarRings.maximumCount)
    }

    /// The enabled set is a ceiling as well as a filter: one provider supplies
    /// exactly two quotas, which is exactly one ring.
    @Test("One enabled provider yields exactly one ring")
    func oneProviderIsOneRing() {
        let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]
        let rings = MenuBarRings(MenuBarRings.default.sources, allowed: claudeOnly)

        #expect(rings.ringCount == 1)
        #expect(rings.sources == [.claudeWeekly, .claudeSession])
    }

    /// Hiding, not deleting: the stored layout keeps the disabled provider's
    /// arcs so switching it back on restores the user's own arrangement.
    @Test("A disabled provider leaves the effective rings but stays on disk")
    func disabledProviderSurvivesOnDisk() {
        var settings = AppSettings()
        settings.menuBarRings = MenuBarRings.default
        settings.codexEnabled = false

        #expect(settings.effectiveMenuBarRings.ringCount == 1)
        #expect(settings.effectiveMenuBarRings.sources == [.claudeWeekly, .claudeSession])
        // Untouched, which is the whole point.
        #expect(settings.menuBarRings.sources == MenuBarRings.default.sources)
    }

    /// The only reading of a drag onto an occupied slot that cannot lose an arc.
    @Test("Dropping a placed source onto another slot swaps the two")
    func dropSwaps() {
        let rings = MenuBarRings.default.replacing(at: 0, with: .codexSession)
        #expect(rings.sources == [.codexSession, .claudeSession, .codexWeekly, .claudeWeekly])
    }

    @Test("Dropping an unplaced source replaces the slot's own")
    func dropReplaces() {
        let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]
        let rings = MenuBarRings([.claudeWeekly, .claudeSession], allowed: claudeOnly)
        // Codex is not in the allowed set, so the drop must be refused rather
        // than accepted into a slot normalization would immediately drop.
        #expect(rings.replacing(at: 0, with: .codexWeekly, allowed: claudeOnly).sources == rings.sources)
    }

    @Test("Growing to two rings fills from the unused sources")
    func growAddsUnused() {
        let one = MenuBarRings([.claudeWeekly, .claudeSession])
        let two = one.resized(toRings: 2)

        #expect(two.ringCount == 2)
        #expect(two.sources.prefix(2) == [.claudeWeekly, .claudeSession])
        #expect(Set(two.sources) == Set(MenuBarQuotaSource.allCases))
    }

    @Test("Shrinking to one ring drops the rightmost")
    func shrinkDropsFromTheRight() {
        #expect(MenuBarRings.default.resized(toRings: 1).sources == [.claudeWeekly, .claudeSession])
    }

    /// Two rings cannot be asked for when only one provider's quotas may be
    /// drawn — the count picker hides in that case, but the model is what
    /// guarantees it.
    @Test("Two rings cannot be reached with one provider enabled")
    func cannotGrowPastTheEnabledSet() {
        let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]
        let rings = MenuBarRings([.claudeWeekly, .claudeSession], allowed: claudeOnly)
        #expect(rings.resized(toRings: 2, allowed: claudeOnly).ringCount == 1)
    }

    @Test("A ring layout round-trips through its bare-array encoding")
    func roundTrips() throws {
        let written = MenuBarRings([.codexSession, .codexWeekly, .claudeSession, .claudeWeekly])
        let data = try JSONStore.makeEncoder().encode(written)
        let read = try JSONStore.makeDecoder().decode(MenuBarRings.self, from: data)
        #expect(read == written)
    }

    /// The decoder has no settings access and must not gain any: restricting to
    /// the enabled providers is strictly a read-time concern.
    @Test("Decoding normalizes against the full universe, not the enabled set")
    func decodeIgnoresEnablement() throws {
        let read = try JSONStore.makeDecoder().decode(
            MenuBarRings.self,
            from: Data("[\"codex.weekly\",\"codex.session\"]".utf8)
        )
        #expect(read.sources == [.codexWeekly, .codexSession])
    }

    @Test("A ring list of the wrong shape falls back instead of throwing")
    func garbageFallsBack() throws {
        let read = try JSONStore.makeDecoder().decode(MenuBarRings.self, from: Data("\"nonsense\"".utf8))
        #expect(read == MenuBarRings.default)
    }
}

@Suite("Menubar ring rendering")
@MainActor
struct MenuBarRingRenderingTests {
    private func pixels(_ image: NSImage) -> Data? { image.tiffRepresentation }

    private var twoRings: [MenuBarIconRenderer.Meter] {
        [.init(fraction: 74), .init(fraction: 39), .init(fraction: 39), .init(fraction: 100)]
    }

    /// The icon may not grow beyond what it declares, or it shoves its
    /// neighbours along the menu bar.
    @Test("A ring icon is exactly the size it declares")
    func ringIconIsItsDeclaredSize() {
        let one = MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 74), .init(fraction: 39)], isStale: false
        )
        let two = MenuBarIconRenderer.image(style: .rings, meters: twoRings, isStale: false)

        #expect(one.size == MenuBarIconRenderer.size(style: .rings, meterCount: 2))
        #expect(two.size == MenuBarIconRenderer.size(style: .rings, meterCount: 4))
        // A lone ring is narrower than the bars it replaces; a pair is wider.
        #expect(one.size.width < MenuBarIconRenderer.barsSize.width)
        #expect(two.size.width > MenuBarIconRenderer.barsSize.width)
    }

    /// Height is the hard constraint. Growing it is what misaligns the icon
    /// against every other item in the menu bar.
    @Test("Rings stay inside the menu bar's height budget")
    func ringsFitTheHeight() {
        let outerEdge = MenuBarIconRenderer.Ring.outerRadius + MenuBarIconRenderer.Ring.strokeWidth / 2
        #expect(outerEdge * 2 <= MenuBarIconRenderer.barsSize.height)
        #expect(MenuBarIconRenderer.size(style: .rings, meterCount: 4).height
            == MenuBarIconRenderer.barsSize.height)
    }

    /// The two arcs have to read as separate meters, not one thick band.
    @Test("The inner and outer arcs do not touch")
    func arcsHaveGround() {
        let stroke = MenuBarIconRenderer.Ring.strokeWidth
        let outerInnerEdge = MenuBarIconRenderer.Ring.outerRadius - stroke / 2
        let innerOuterEdge = MenuBarIconRenderer.Ring.innerRadius + stroke / 2
        #expect(outerInnerEdge - innerOuterEdge >= 0.75)
    }

    @Test("A neutral ring icon is a template and a lit one is not")
    func templatingFollowsColour() {
        let neutral = MenuBarIconRenderer.image(style: .rings, meters: twoRings, isStale: false)
        let ready = MenuBarIconRenderer.image(
            style: .rings,
            meters: twoRings.map { .init(fraction: $0.fraction, isReady: true) },
            isStale: false
        )
        #expect(neutral.isTemplate)
        #expect(!ready.isTemplate)
    }

    @Test("Lighting a ring changes what is drawn")
    func readyChangesOutput() throws {
        let neutral = try #require(pixels(
            MenuBarIconRenderer.image(style: .rings, meters: twoRings, isStale: false)
        ))
        let ready = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings,
            meters: twoRings.map { .init(fraction: $0.fraction, isReady: true) },
            isStale: false
        )))
        #expect(neutral != ready)
    }

    /// The dim is hierarchy, not a state. A ring with something to announce
    /// must not be quieter than one without.
    @Test("The outer arc is dimmed while neutral but not while lit")
    func outerDimOnlyWhenNeutral() throws {
        let neutralOuterFirst = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 80), .init(fraction: 40)], isStale: false
        )))
        // Same two numbers, swapped between the arcs. With the outer dimmed the
        // two images cannot match; without the dim they would be near-identical
        // readings and this test would not be worth writing.
        let neutralInnerFirst = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 40), .init(fraction: 80)], isStale: false
        )))
        #expect(neutralOuterFirst != neutralInnerFirst)

        let litOuter = MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 80, isReady: true), .init(fraction: 40)], isStale: false
        )
        // A lit outer arc draws at full strength, so it is not the dimmed one.
        let dimmedOuter = MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 80), .init(fraction: 40)], isStale: false
        )
        #expect(pixels(litOuter) != pixels(dimmedOuter))
    }

    /// The ring counterpart of the bar's nub: 1% has to be visibly distinct
    /// from 0%, or a nearly-spent window reads as an empty one.
    @Test("One percent draws an arc and zero draws none")
    func minimumArc() throws {
        let one = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 1), .init(fraction: 50)], isStale: false
        )))
        let zero = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 0), .init(fraction: 50)], isStale: false
        )))
        #expect(one != zero)
    }

    /// Stale data must never be dressed up as an opportunity, in either shape.
    @Test("Stale rings never glow")
    func staleNeverGlows() throws {
        let plain = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: nil, isReady: true), .init(fraction: nil, isReady: true)],
            isStale: true
        )))
        let asked = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: nil, isReady: true), .init(fraction: nil, isReady: true)],
            isStale: true, glow: true
        )))
        #expect(plain == asked)
    }

    /// An unreadable ring still has to look like a meter with no reading,
    /// rather than a blank slot.
    @Test("An unknown reading draws a stub, not an empty ring")
    func unknownDrawsStub() throws {
        let unknown = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: nil), .init(fraction: nil)], isStale: true
        )))
        let empty = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 0), .init(fraction: 0)], isStale: false
        )))
        #expect(unknown != empty)
    }

    /// The dim is a multiplier, not an assignment. Assigning it discarded the
    /// 0.45 `meterColor` gives a stale reading, which drew unreadable data at
    /// full strength — the one thing the mute exists to prevent.
    @Test("A stale ring stays muted rather than drawing at full strength")
    func staleKeepsItsMute() throws {
        let stale = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: 40), .init(fraction: 70)], isStale: true
        )))
        // The same stubs drawn without the stale mute: if the mute were being
        // overwritten these would be the same image.
        let live = try #require(pixels(MenuBarIconRenderer.image(
            style: .rings, meters: [.init(fraction: nil), .init(fraction: nil)], isStale: false
        )))
        #expect(stale != live)
    }

    /// Two styles draw the same reading differently, so the style has to be
    /// part of the cache identity — otherwise switching it in Settings leaves
    /// the old icon on screen.
    @Test("The style is part of the image cache identity")
    func styleIsCached() {
        MenuBarIconRenderer.invalidateCache()
        let meters: [MenuBarIconRenderer.Meter] = [.init(fraction: 40), .init(fraction: 70)]

        let bars = MenuBarIconRenderer.cachedImage(style: .bars, meters: meters, isStale: false)
        let rings = MenuBarIconRenderer.cachedImage(style: .rings, meters: meters, isStale: false)
        #expect(bars !== rings)

        #expect(MenuBarIconRenderer.cachedImage(style: .rings, meters: meters, isStale: false) === rings)
    }
}

@Suite("Menubar icon layout resolution")
struct MenuBarIconLayoutTests {
    @Test("The layout carries its own style, so the two cannot drift apart")
    func layoutCarriesStyle() {
        #expect(MenuBarIconLayout.bars(.default).style == .bars)
        #expect(MenuBarIconLayout.rings(.default).style == .rings)
        #expect(MenuBarIconLayout.rings(.default).sources == MenuBarRings.default.sources)
    }

    @Test("The effective layout follows the configured style")
    func settingsResolveTheLayout() {
        var settings = AppSettings()
        #expect(settings.effectiveMenuBarLayout.style == .bars)

        settings.menuBarIconStyle = .rings
        #expect(settings.effectiveMenuBarLayout.style == .rings)
        #expect(settings.effectiveMenuBarLayout.sources == MenuBarRings.default.sources)
    }
}
