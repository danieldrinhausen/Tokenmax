import AppKit
import Foundation
import Testing

@testable import Tokenmax

@Suite("Menubar escalation ladder")
struct MenuBarEscalationTests {
    private let amber = HighlightColor(red: 1.00, green: 0.75, blue: 0.20)
    private let red = HighlightColor(red: 1.00, green: 0.36, blue: 0.30)

    private func ladder(_ levels: [MenuBarEscalationLevel], base: HighlightColor? = nil) -> MenuBarEscalation {
        MenuBarEscalation(baseColor: base, levels: levels)
    }

    /// Off until asked for, and neutral until a level is reached — the two
    /// defaults that together mean an upgrade repaints nobody.
    @Test("Escalation is off by default and its base is neutral")
    func defaultsAreQuiet() {
        #expect(AppSettings().menuBarColorScheme == .monochrome)
        #expect(AppSettings().effectiveEscalation == nil)
        #expect(MenuBarEscalation.default.baseColor == nil)
    }

    /// Both default rungs have to survive a light *and* a dark menu bar, since
    /// contrast follows the wallpaper. A saturated red does not.
    @Test("Both default rungs are legible on any menu bar")
    func defaultColoursAreLegible() {
        #expect(MenuBarEscalation.default.colors.allSatisfy { $0.isLegibleOnAnyMenuBar })
    }

    // MARK: - Reaching a level

    /// "At or below", so the boundary itself counts. Off by one here would make
    /// a level set at 25 silently mean 24.
    @Test("A threshold is reached exactly at its own percentage")
    func boundaryIsInclusive() {
        let l = ladder([.init(trigger: .remainingAtOrBelow(25), color: red)])

        #expect(MenuBarEscalationDecision.reached(fraction: 25, isAlerting: false, escalation: l)?.color == red)
        #expect(MenuBarEscalationDecision.reached(fraction: 24.9, isAlerting: false, escalation: l)?.color == red)
        #expect(MenuBarEscalationDecision.reached(fraction: 25.1, isAlerting: false, escalation: l) == nil)
    }

    @Test("The most severe reached rung wins")
    func mostSevereWins() {
        let l = MenuBarEscalation.default

        #expect(MenuBarEscalationDecision.reached(fraction: 80, isAlerting: false, escalation: l) == nil)
        #expect(MenuBarEscalationDecision.reached(fraction: 40, isAlerting: false, escalation: l)?.color == amber)
        #expect(MenuBarEscalationDecision.reached(fraction: 10, isAlerting: false, escalation: l)?.color == red)
    }

    /// Without a number there is nothing to be alarmed about, and colouring it
    /// would dress missing data up as a measurement.
    @Test("An unknown reading reaches no percentage rung")
    func unknownReachesNothing() {
        let l = MenuBarEscalation.default
        #expect(MenuBarEscalationDecision.reached(fraction: nil, isAlerting: false, escalation: l) == nil)
        #expect(MenuBarEscalationDecision.reached(fraction: .nan, isAlerting: false, escalation: l) == nil)
    }

    @Test("A reminder rung fires on the alert flag and not on the number")
    func reminderRungFollowsTheAlert() {
        let l = ladder([.init(trigger: .reminderFired, color: red)])

        #expect(MenuBarEscalationDecision.reached(fraction: 90, isAlerting: true, escalation: l)?.color == red)
        #expect(MenuBarEscalationDecision.reached(fraction: 2, isAlerting: false, escalation: l) == nil)
        // No reading at all still counts: the reminder is about what the user
        // was told, not about a number.
        #expect(MenuBarEscalationDecision.reached(fraction: nil, isAlerting: true, escalation: l) != nil)
    }

    /// The distinction the whole precedence turns on. A percentage is a
    /// statement about the quota; a fired reminder is bookkeeping.
    @Test("A percentage rung outranks the highlight and a reminder rung does not")
    func precedenceSplitsByTrigger() {
        let percent = ladder([.init(trigger: .remainingAtOrBelow(25), color: red)])
        let reminder = ladder([.init(trigger: .reminderFired, color: red)])

        #expect(
            MenuBarEscalationDecision.reached(fraction: 10, isAlerting: false, escalation: percent)?
                .outranksHighlight == true
        )
        #expect(
            MenuBarEscalationDecision.reached(fraction: 90, isAlerting: true, escalation: reminder)?
                .outranksHighlight == false
        )
    }

    // MARK: - The colour that actually gets drawn

    /// 15% left is not an opportunity however close the reset is, so the icon
    /// must not contradict the popover by painting it the highlight colour.
    @Test("A low window is drawn its escalation colour even while it is ready")
    func percentRungBeatsTheHighlight() {
        let l = ladder([.init(trigger: .remainingAtOrBelow(25), color: red)])
        let color = MenuBarIconRenderer.meterColor(
            isStale: false, isReady: true, templated: false, fraction: 15, escalation: l
        )
        #expect(color == red.nsColor)
        #expect(color != HighlightColor.default.nsColor)
    }

    /// A window with 80% left that happens to have been announced is still an
    /// opportunity — the rule `meterColor` already applied to `isAlerting`.
    @Test("A reminder rung yields to the highlight")
    func reminderRungYieldsToTheHighlight() {
        let l = ladder([.init(trigger: .reminderFired, color: red)])
        let color = MenuBarIconRenderer.meterColor(
            isStale: false, isReady: true, isAlerting: true, templated: false, fraction: 80, escalation: l
        )
        #expect(color == HighlightColor.default.nsColor)
    }

    /// Stale outranks everything: there is no reading to colour, and dressing
    /// unconfirmed data in a warning colour is the one thing the mute exists
    /// to prevent.
    @Test("A stale meter is never escalated")
    func staleIsNeverColoured() {
        let l = MenuBarEscalation.default
        let color = MenuBarIconRenderer.meterColor(
            isStale: true, isReady: false, templated: false, fraction: 5, escalation: l
        )
        #expect(color != MenuBarEscalation.default.levels.first?.color.nsColor)
        #expect(color.alphaComponent < 1)
    }

    /// Two competing warm colours on one arc are worse than one: the user
    /// cannot rank them, so the second only makes the first ambiguous.
    @Test("The fixed alert orange steps aside once a ladder is configured")
    func alertOrangeStepsAside() {
        let monochrome = MenuBarIconRenderer.meterColor(
            isStale: false, isReady: false, isAlerting: true, templated: false, fraction: 70
        )
        #expect(monochrome == MenuBarIconRenderer.alertColor)

        // A ladder with no reminder rung, on a reading that trips nothing: the
        // meter goes neutral rather than orange.
        let escalating = MenuBarIconRenderer.meterColor(
            isStale: false, isReady: false, isAlerting: true, templated: false,
            fraction: 70, escalation: ladder([.init(trigger: .remainingAtOrBelow(25), color: red)])
        )
        #expect(escalating != MenuBarIconRenderer.alertColor)
        #expect(escalating == MenuBarIconRenderer.untemplatedNeutralColor)
    }

    @Test("A base colour paints a meter that has reached nothing")
    func baseColourPaintsTheHealthyCase() {
        let green = HighlightColor(red: 0.16, green: 0.85, blue: 0.35)
        let l = ladder([.init(trigger: .remainingAtOrBelow(25), color: red)], base: green)

        #expect(MenuBarIconRenderer.meterColor(
            isStale: false, isReady: false, templated: false, fraction: 90, escalation: l
        ) == green.nsColor)
    }

    // MARK: - Templating

    /// The proof that nobody gets a new icon: with escalation off, the drawing
    /// is byte-identical to the one that shipped before it existed.
    @Test("Monochrome draws exactly what it drew before escalation existed")
    @MainActor
    func monochromeIsUnchanged() throws {
        let meters: [MenuBarIconRenderer.Meter] = [.init(fraction: 12), .init(fraction: 70, isAlerting: true)]
        let without = try #require(
            MenuBarIconRenderer.image(meters: meters, isStale: false).tiffRepresentation
        )
        let explicitlyOff = try #require(
            MenuBarIconRenderer.image(meters: meters, isStale: false, escalation: nil).tiffRepresentation
        )
        #expect(without == explicitlyOff)
    }

    @Test("A reached rung takes the icon out of templating")
    @MainActor
    func escalationEndsTemplating() {
        let l = MenuBarEscalation.default
        let healthy = MenuBarIconRenderer.image(
            meters: [.init(fraction: 90), .init(fraction: 80)], isStale: false, escalation: l
        )
        let low = MenuBarIconRenderer.image(
            meters: [.init(fraction: 90), .init(fraction: 10)], isStale: false, escalation: l
        )
        // Nothing reached, no base colour: still a template, so the icon keeps
        // matching its neighbours on any wallpaper.
        #expect(healthy.isTemplate)
        #expect(!low.isTemplate)
    }

    /// A base colour is always-on colour, so it ends templating permanently.
    /// That is the cost the setting's caption has to name.
    @Test("A base colour ends templating even with nothing reached")
    @MainActor
    func baseColourEndsTemplating() {
        let l = MenuBarEscalation(baseColor: .default, levels: [])
        let image = MenuBarIconRenderer.image(
            meters: [.init(fraction: 90), .init(fraction: 80)], isStale: false, escalation: l
        )
        #expect(!image.isTemplate)
    }

    /// A stale-only icon still tints itself to the menu bar.
    @Test("Staleness alone does not end templating")
    @MainActor
    func staleStaysTemplated() {
        let image = MenuBarIconRenderer.image(
            meters: [.init(fraction: nil), .init(fraction: nil)], isStale: true,
            escalation: MenuBarEscalation.default
        )
        #expect(image.isTemplate)
    }

    /// Without this, editing a rung in Settings would leave the old icon on
    /// screen until something else happened to change.
    @Test("The ladder is part of the image cache identity")
    @MainActor
    func ladderIsCached() {
        MenuBarIconRenderer.invalidateCache()
        let meters: [MenuBarIconRenderer.Meter] = [.init(fraction: 40), .init(fraction: 70)]

        let plain = MenuBarIconRenderer.cachedImage(meters: meters, isStale: false)
        let escalated = MenuBarIconRenderer.cachedImage(
            meters: meters, isStale: false, escalation: MenuBarEscalation.default
        )
        #expect(plain !== escalated)
        #expect(MenuBarIconRenderer.cachedImage(
            meters: meters, isStale: false, escalation: MenuBarEscalation.default
        ) === escalated)
    }

    // MARK: - Normalization

    @Test("The ladder is sorted most severe first, whatever order it arrives in")
    func ladderIsSorted() {
        let l = ladder([
            .init(trigger: .remainingAtOrBelow(25), color: red),
            .init(trigger: .remainingAtOrBelow(75), color: amber),
            .init(trigger: .remainingAtOrBelow(50), color: amber),
        ])
        #expect(l.levels.map(\.trigger) == [
            .remainingAtOrBelow(25), .remainingAtOrBelow(50), .remainingAtOrBelow(75),
        ])
    }

    /// A reminder rung has no place on the percentage scale, so it sorts last
    /// and is only ever compared against itself.
    @Test("A reminder rung sorts below every percentage rung")
    func reminderSortsLast() {
        let l = ladder([
            .init(trigger: .reminderFired, color: red),
            .init(trigger: .remainingAtOrBelow(50), color: amber),
        ])
        #expect(l.levels.last?.trigger == .reminderFired)
    }

    /// A second one could never fire: the first already matches every reading
    /// it would.
    @Test("Only one reminder rung survives")
    func oneReminderRung() {
        let l = ladder([
            .init(trigger: .reminderFired, color: red),
            .init(trigger: .reminderFired, color: amber),
        ])
        #expect(l.levels.count == 1)
        #expect(l.levels.first?.color == red)
    }

    /// Two rungs at the same threshold are one rung and a colour nobody sees.
    @Test("Duplicate thresholds collapse")
    func duplicateThresholdsCollapse() {
        let l = ladder([
            .init(trigger: .remainingAtOrBelow(50), color: amber),
            .init(trigger: .remainingAtOrBelow(50), color: red),
        ])
        #expect(l.levels.count == 1)
        #expect(l.levels.first?.color == amber)
    }

    /// A rung at 0 could only fire on an exhausted window; one at 100 would
    /// fire always. Both are a ladder that says nothing.
    @Test("Thresholds are clamped into a range where they can mean something")
    func thresholdsAreClamped() {
        let l = ladder([
            .init(trigger: .remainingAtOrBelow(-10), color: red),
            .init(trigger: .remainingAtOrBelow(400), color: amber),
        ])
        #expect(l.levels.map(\.trigger) == [.remainingAtOrBelow(1), .remainingAtOrBelow(99)])
    }

    @Test("Three rungs is the ceiling")
    func threeRungsIsTheCeiling() {
        let l = ladder([
            .init(trigger: .remainingAtOrBelow(80), color: amber),
            .init(trigger: .remainingAtOrBelow(60), color: amber),
            .init(trigger: .remainingAtOrBelow(40), color: red),
            .init(trigger: .remainingAtOrBelow(20), color: red),
        ])
        #expect(l.levels.count == MenuBarEscalation.maximumLevels)
        // Kept from the severe end, which is the half that matters.
        #expect(l.levels.map(\.trigger) == [
            .remainingAtOrBelow(20), .remainingAtOrBelow(40), .remainingAtOrBelow(60),
        ])
    }

    // MARK: - Persistence

    @Test("A ladder round-trips")
    func roundTrips() throws {
        let written = ladder([
            .init(trigger: .remainingAtOrBelow(60), color: amber),
            .init(trigger: .reminderFired, color: red),
        ], base: .default)

        let data = try JSONStore.makeEncoder().encode(written)
        let read = try JSONStore.makeDecoder().decode(MenuBarEscalation.self, from: data)
        #expect(read == written)
        #expect(read.baseColor == .default)
    }

    /// The point of the separate wire type: one broken rung costs that rung,
    /// not the ladder and not the settings file.
    @Test("A rung with an unreadable trigger drops on its own")
    func brokenRungDropsAlone() throws {
        let read = try JSONStore.makeDecoder().decode(MenuBarEscalation.self, from: Data("""
        { "levels": [
            { "color": { "red": 1, "green": 0.75, "blue": 0.2 } },
            { "remainingAtOrBelow": 25, "color": { "red": 1, "green": 0.36, "blue": 0.3 } }
        ] }
        """.utf8))

        #expect(read.levels.count == 1)
        #expect(read.levels.first?.trigger == .remainingAtOrBelow(25))
    }

    @Test("A ladder of the wrong shape falls back rather than throwing")
    func garbageFallsBack() throws {
        let settings = try JSONStore.makeDecoder().decode(AppSettings.self, from: Data("""
        { "menuBarEscalation": "nonsense", "remindersEnabled": true }
        """.utf8))

        #expect(settings.menuBarEscalation == .default)
        #expect(settings.remindersEnabled)
    }

    @Test("An unrecognised colour scheme falls back instead of throwing")
    func unknownSchemeFallsBack() throws {
        let settings = try JSONStore.makeDecoder().decode(AppSettings.self, from: Data("""
        { "menuBarColorScheme": "someRetiredScheme", "remindersEnabled": true }
        """.utf8))

        #expect(settings.menuBarColorScheme == .monochrome)
        #expect(settings.remindersEnabled)
    }

    /// Switching the scheme off must not discard the rungs the user built.
    @Test("The ladder survives switching escalation off")
    func ladderSurvivesBeingSwitchedOff() {
        var settings = AppSettings()
        settings.menuBarColorScheme = .escalating
        settings.menuBarEscalation = ladder([.init(trigger: .remainingAtOrBelow(80), color: amber)])

        settings.menuBarColorScheme = .monochrome
        #expect(settings.effectiveEscalation == nil)
        #expect(settings.menuBarEscalation.levels.count == 1)
    }
}
