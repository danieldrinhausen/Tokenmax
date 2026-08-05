import AppKit
import Foundation
import Testing

@testable import Tokenmax

@Suite("Menubar bar layout")
struct MenuBarBarsTests {
    @Test("The default layout is the icon Tokenmax has always drawn")
    func defaultLayout() {
        #expect(MenuBarBars.default.sources == [.claudeSession, .claudeWeekly])
    }

    /// A repeat would draw the same number twice and waste a slot.
    @Test("Duplicates are collapsed")
    func duplicatesCollapse() {
        let bars = MenuBarBars([.claudeWeekly, .claudeWeekly, .codexWeekly])
        #expect(bars.sources == [.claudeWeekly, .codexWeekly])
    }

    /// Below two bars there is no icon to draw, so a short list is padded from
    /// the canonical order rather than rendered empty.
    @Test("A too-short layout is padded, not left empty")
    func shortLayoutIsPadded() {
        #expect(MenuBarBars([]).count == 2)
        #expect(MenuBarBars([.codexWeekly]).count == 2)
        #expect(MenuBarBars([.codexWeekly]).sources.first == .codexWeekly)
    }

    @Test("More sources than slots are truncated")
    func longLayoutIsTruncated() {
        let bars = MenuBarBars(MenuBarQuotaSource.allCases + [.claudeSession])
        #expect(bars.count == MenuBarBars.maximumCount)
    }

    @Test("Resizing grows from unused sources and shrinks from the bottom")
    func resizing() {
        let two = MenuBarBars([.claudeSession, .claudeWeekly])
        let three = two.resized(to: 3)
        #expect(three.sources == [.claudeSession, .claudeWeekly, .codexWeekly])
        #expect(three.resized(to: 2).sources == [.claudeSession, .claudeWeekly])
    }

    @Test("Resizing is clamped to the drawable range")
    func resizingIsClamped() {
        let bars = MenuBarBars.default
        #expect(bars.resized(to: 0).count == MenuBarBars.minimumCount)
        #expect(bars.resized(to: 9).count == MenuBarBars.maximumCount)
    }

    /// Dropping an already-placed source onto another slot has to swap, not
    /// overwrite — overwriting would delete a bar the user never asked to lose.
    @Test("Dropping a placed source onto another slot swaps them")
    func dropSwaps() {
        let bars = MenuBarBars([.claudeSession, .claudeWeekly])
        let swapped = bars.replacing(at: 0, with: .claudeWeekly)

        #expect(swapped.sources == [.claudeWeekly, .claudeSession])
        #expect(swapped.count == 2)
    }

    @Test("Dropping an unused source replaces the slot")
    func dropReplaces() {
        let bars = MenuBarBars([.claudeSession, .claudeWeekly])
        #expect(bars.replacing(at: 1, with: .codexWeekly).sources == [.claudeSession, .codexWeekly])
    }

    @Test("An out-of-range drop is ignored rather than crashing")
    func dropOutOfRange() {
        let bars = MenuBarBars.default
        #expect(bars.replacing(at: 7, with: .codexWeekly) == bars)
    }

    @Test("Unused lists exactly what is not on a bar")
    func unusedSources() {
        #expect(MenuBarBars([.claudeSession, .claudeWeekly]).unused() == [.codexWeekly, .codexSession])
        // More sources exist than there are slots, so the layout that uses every
        // slot still leaves one over.
        #expect(MenuBarBars(MenuBarQuotaSource.allCases).unused() == [.codexSession])
    }

    @Test("Each source maps to the provider and window it names")
    func sourceMapping() {
        #expect(MenuBarQuotaSource.claudeSession.provider == .claudeCode)
        #expect(MenuBarQuotaSource.claudeSession.kind == .session)
        #expect(MenuBarQuotaSource.claudeWeekly.provider == .claudeCode)
        #expect(MenuBarQuotaSource.claudeWeekly.kind == .weekly)
        #expect(MenuBarQuotaSource.codexWeekly.provider == .codex)
        #expect(MenuBarQuotaSource.codexWeekly.kind == .weekly)
        #expect(MenuBarQuotaSource.codexSession.provider == .codex)
        #expect(MenuBarQuotaSource.codexSession.kind == .session)
    }

    // MARK: - Disabled providers

    private static let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]

    @Test("A disabled provider's source cannot be padded back in")
    func disabledSourceIsNotPadded() {
        let bars = MenuBarBars([.codexWeekly], allowed: Self.claudeOnly)
        #expect(bars.sources == [.claudeSession, .claudeWeekly])
    }

    /// Codex reports one drawable quota on most accounts, and one bar is
    /// drawable where an empty icon is not.
    @Test("A single enabled quota collapses to one bar")
    func singleEnabledSourceIsOneBar() {
        let bars = MenuBarBars(MenuBarBars.default.sources, allowed: [.codexWeekly])
        #expect(bars.sources == [.codexWeekly])
    }

    @Test("Growing cannot exceed the enabled sources")
    func growIsCappedByEnabledSet() {
        let bars = MenuBarBars([.codexWeekly], allowed: [.codexWeekly])
        #expect(bars.resized(to: 3, allowed: [.codexWeekly]).count == 1)
        #expect(MenuBarBars.default.resized(to: 3, allowed: Self.claudeOnly).count == 2)
    }

    @Test("A drop of a disabled source is ignored")
    func disabledDropIsIgnored() {
        let bars = MenuBarBars.default
        #expect(bars.replacing(at: 0, with: .codexWeekly, allowed: Self.claudeOnly) == bars)
    }

    @Test("Unused lists only enabled sources")
    func unusedRespectsEnabledSet() {
        #expect(MenuBarBars.default.unused(allowed: Self.claudeOnly).isEmpty)
    }

    /// The backstop for a hand-edited file that switches every source off.
    @Test("An empty allowed set falls back rather than producing an undrawable icon")
    func emptyAllowedFallsBack() {
        #expect(MenuBarBars(MenuBarBars.default.sources, allowed: []).count == 2)
        #expect(MenuBarBars.default.resized(to: 3, allowed: []).count == 3)
    }

    /// The "settings are kept, not deleted" contract: the stored layout keeps
    /// the disabled provider's slot, and only the *read* through
    /// `effectiveMenuBarBars` drops it.
    @Test("A disabled provider's slot survives a round trip")
    func disabledSlotSurvivesRoundTrip() throws {
        var settings = AppSettings()
        settings.menuBarBars = MenuBarBars([.claudeSession, .claudeWeekly, .codexWeekly])
        settings.codexEnabled = false

        let data = try JSONStore.makeEncoder().encode(settings)
        let decoded = try JSONStore.makeDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.menuBarBars.sources.contains(.codexWeekly))
        #expect(decoded.effectiveMenuBarBars.sources == [.claudeSession, .claudeWeekly])
    }

    @Test("A countdown pointing at a disabled provider falls back to an enabled one")
    func countdownFallsBack() {
        var settings = AppSettings()
        settings.menuBarCountdownSource = .codexWeekly
        #expect(settings.effectiveCountdownSource == .codexWeekly)

        settings.codexEnabled = false
        #expect(settings.effectiveCountdownSource == .claudeSession)
    }

    /// Settings survive a round trip, and a hand-edited file cannot produce an
    /// undrawable icon.
    @Test("Layouts round-trip, and a corrupt one falls back")
    func codableRoundTrip() throws {
        let bars = MenuBarBars([.codexWeekly, .claudeSession, .claudeWeekly])
        let data = try JSONEncoder().encode(bars)
        #expect(try JSONDecoder().decode(MenuBarBars.self, from: data) == bars)

        let garbage = try #require("[\"not.a.source\"]".data(using: .utf8))
        #expect(try JSONDecoder().decode(MenuBarBars.self, from: garbage) == .default)
    }

    /// Adding this setting must not reset a settings file written before it
    /// existed.
    @Test("Settings written before bars existed still decode")
    func settingsWithoutBarsDecode() throws {
        let json = try #require("{\"remindersEnabled\": true}".data(using: .utf8))
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        #expect(settings.remindersEnabled)
        #expect(settings.menuBarBars == .default)
        #expect(settings.codexWeeklyReminder == .codexWeeklyDefault)
    }
}

@Suite("Menubar icon model")
struct MenuBarIconModelTests {
    private func snapshot(
        provider: TokenmaxProvider,
        session: Double? = nil,
        weekly: Double? = nil,
        sessionResetAt: Date? = nil
    ) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let session {
            windows.append(UsageWindow(
                id: "\(provider.rawValue).session",
                kind: .session,
                label: "Session",
                usedPercent: 100 - session,
                resetAt: sessionResetAt,
                observedAt: Date(),
                source: .claudeOAuth,
                confidence: .authoritative
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "\(provider.rawValue).weekly",
                kind: .weekly,
                label: "Weekly",
                usedPercent: 100 - weekly,
                resetAt: nil,
                observedAt: Date(),
                source: .claudeOAuth,
                confidence: .authoritative
            ))
        }
        return UsageSnapshot(
            providerID: provider.rawValue,
            planName: nil,
            windows: windows,
            fetchedAt: Date(),
            fetchDuration: 0,
            errorMessage: nil
        )
    }

    @Test("Bars are built in the configured order")
    func barsFollowLayout() {
        let claude = snapshot(provider: .claudeCode, session: 40, weekly: 70)
        let codex = snapshot(provider: .codex, weekly: 90)

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.codexWeekly, .claudeSession, .claudeWeekly]),
            countdownSource: .claudeSession,
            snapshot: { $0 == .codex ? codex : claude },
            isStale: { _ in false },
            alerting: [],
            ready: []
        )

        #expect(model.bars.map(\.fraction) == [90, 40, 70])
    }

    /// The whole point of splitting staleness per provider: one provider going
    /// stale must not blank the other's reading.
    @Test("One stale provider stubs only its own bar")
    func staleIsPerProvider() {
        let claude = snapshot(provider: .claudeCode, session: 40, weekly: 70)
        let codex = snapshot(provider: .codex, weekly: 90)

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .codexWeekly]),
            countdownSource: .claudeSession,
            snapshot: { $0 == .codex ? codex : claude },
            isStale: { $0 == .codex },
            alerting: [],
            ready: []
        )

        #expect(model.bars.map(\.fraction) == [40, nil])
        // Not every shown provider is stale, so the icon as a whole stays live.
        #expect(!model.isStale)
    }

    @Test("The icon mutes only when every shown provider is stale")
    func wholeIconStale() {
        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .claudeWeekly]),
            countdownSource: .claudeSession,
            snapshot: { _ in nil },
            isStale: { _ in true },
            alerting: [],
            ready: []
        )

        #expect(model.isStale)
    }

    @Test("Only the alerting window's bar carries the alert")
    func alertingIsPerBar() {
        let claude = snapshot(provider: .claudeCode, session: 40, weekly: 70)

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .claudeWeekly]),
            countdownSource: .claudeSession,
            snapshot: { _ in claude },
            isStale: { _ in false },
            alerting: [.claudeWeekly],
            ready: []
        )

        #expect(model.bars.map(\.isAlerting) == [false, true])
    }

    /// The countdown is configured separately from the bars, so it must read
    /// the source it was given rather than inferring one from the layout.
    @Test("The countdown follows its own setting")
    func countdownFollowsItsOwnSetting() {
        let reset = Date().addingTimeInterval(3600)
        let claude = snapshot(provider: .claudeCode, session: 40, weekly: 70, sessionResetAt: reset)
        let codex = snapshot(provider: .codex, weekly: 90)

        let followingSession = MenuBarIconModel.make(
            layout: MenuBarBars([.codexWeekly, .claudeWeekly]),
            countdownSource: .claudeSession,
            snapshot: { $0 == .codex ? codex : claude },
            isStale: { _ in false },
            alerting: [],
            ready: []
        )
        // Deliberately a window no bar is showing — that is allowed.
        #expect(followingSession.countdownResetAt == reset)

        // Codex's weekly carries no reset time here, so the label collapses.
        let followingCodex = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .claudeWeekly]),
            countdownSource: .codexWeekly,
            snapshot: { $0 == .codex ? codex : claude },
            isStale: { _ in false },
            alerting: [],
            ready: []
        )
        #expect(followingCodex.countdownResetAt == nil)
    }

    /// Staleness follows the countdown's own provider, not the icon's.
    @Test("A stale countdown provider suppresses the text even when bars are fresh")
    func countdownStaleness() {
        let claude = snapshot(
            provider: .claudeCode, session: 40, weekly: 70,
            sessionResetAt: Date().addingTimeInterval(3600)
        )

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .codexWeekly]),
            countdownSource: .claudeSession,
            snapshot: { _ in claude },
            isStale: { $0 == .claudeCode },
            alerting: [],
            ready: []
        )

        #expect(model.countdownIsStale)
        // Only one of the two shown providers is stale, so the bars stay live.
        #expect(!model.isStale)
    }

    /// A weekly window is days away, and "162:18" is neither readable as a
    /// duration nor narrow enough for a menu bar.
    @Test("Resets more than a day out read as days and hours")
    func longCountdownsUseDays() {
        let now = Date()

        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(6 * 86400 + 18 * 3600), now: now
        ) == "6d 18h")

        // The hour/minute format holds right up to the boundary.
        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(23 * 3600 + 59 * 60), now: now
        ) == "23:59")
        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(24 * 3600), now: now
        ) == "1d 0h")
    }

    /// The bug this exists to prevent: `isReady` was one flag handed to every
    /// bar, sourced from the selected provider's *session* window. A Codex
    /// weekly window with four days left was painted "spend it now" because
    /// Claude's session was about to reset — a bar reporting a state that was
    /// never its own.
    @Test("Only the bar whose own window is a burn opportunity lights up")
    func readinessIsPerSource() {
        let claude = snapshot(provider: .claudeCode, session: 80, weekly: 56)
        let codex = snapshot(provider: .codex, weekly: 85)

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .codexWeekly]),
            countdownSource: .claudeSession,
            snapshot: { $0 == .codex ? codex : claude },
            isStale: { _ in false },
            alerting: [],
            ready: [.claudeSession]
        )

        #expect(model.bars.map(\.isReady) == [true, false])
    }

    /// Same reason `fraction` is nil for a stale provider: a bar with no reading
    /// has no opportunity to announce either.
    @Test("A stale provider's bar is never ready")
    func staleBarIsNeverReady() {
        let claude = snapshot(provider: .claudeCode, session: 80, weekly: 56)

        let model = MenuBarIconModel.make(
            layout: MenuBarBars([.claudeSession, .claudeWeekly]),
            countdownSource: .claudeSession,
            snapshot: { _ in claude },
            isStale: { _ in true },
            alerting: [],
            ready: [.claudeSession]
        )

        #expect(model.bars.allSatisfy { !$0.isReady })
    }
}

@Suite("Menubar alert colouring")
@MainActor
struct MenuBarAlertColourTests {
    /// The reason the alert exists: a fired reminder must stay visible on the
    /// icon for the rest of the window, not just at the instant of delivery.
    @Test("A fired reminder colours its bar until the window resets")
    func firedReminderAlerts() {
        #expect(ReminderStatus.justDelivered.hasFiredForCurrentWindow)
        #expect(ReminderStatus.suppressed(.alreadyFiredForWindow, firedAt: Date()).hasFiredForCurrentWindow)

        #expect(!ReminderStatus.scheduled(Date()).hasFiredForCurrentWindow)
        #expect(!ReminderStatus.suppressed(.quietHours, firedAt: nil).hasFiredForCurrentWindow)
        #expect(!ReminderStatus.suppressed(.notEnoughQuotaLeft, firedAt: nil).hasFiredForCurrentWindow)
    }

    /// "Now is a good time to spend this" is a statement about quota. "Already
    /// notified" is bookkeeping about a notification, and says nothing about how
    /// much is left. When both are true of one window the quota fact has to win,
    /// or a bar with 80% remaining is painted the warning colour while the
    /// popover calls the same window a good time to spend.
    @Test("The burn highlight outranks an already-fired reminder")
    func highlightBeatsAlert() {
        let both = MenuBarIconRenderer.barColor(
            isStale: false, isReady: true, isAlerting: true, templated: false
        )
        #expect(both == MenuBarIconRenderer.readyColor)
        #expect(both != MenuBarIconRenderer.alertColor)
    }

    /// The alert keeps the case it was actually meant for: a window that has
    /// been announced and is no longer a burn opportunity, which is the one
    /// that genuinely warrants a warning colour.
    @Test("An alert still colours a bar that is not a burn opportunity")
    func alertAppliesWithoutHighlight() {
        let alerting = MenuBarIconRenderer.barColor(
            isStale: false, isReady: false, isAlerting: true, templated: false
        )
        #expect(alerting == MenuBarIconRenderer.alertColor)
    }

    /// Stale data must never be dressed up — including as an alert.
    @Test("Stale data never alerts")
    func staleNeverAlerts() {
        let stale = MenuBarIconRenderer.barColor(
            isStale: true, isReady: false, isAlerting: true, templated: false
        )
        #expect(stale != MenuBarIconRenderer.alertColor)
    }

    /// A template is flattened to one tint, so an alerting icon has to opt out
    /// of templating or the colour it exists for is thrown away.
    @Test("An alerting icon stops being a template")
    func alertingIconIsNotTemplated() {
        let plain = MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false
        )
        let alerting = MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70, isAlerting: true)], isStale: false
        )

        #expect(plain.isTemplate)
        #expect(!alerting.isTemplate)
        #expect(plain.tiffRepresentation != alerting.tiffRepresentation)
    }

    /// Grey is the only neutral that survives both a light and a dark menu bar,
    /// which is what an untemplated icon has to cope with.
    @Test("Untemplated neutral bars stay legible on any menu bar")
    func untemplatedNeutralIsLegible() throws {
        let grey = try #require(MenuBarIconRenderer.untemplatedNeutralColor.usingColorSpace(.sRGB))
        let luminance = HighlightColor(
            red: Double(grey.redComponent),
            green: Double(grey.greenComponent),
            blue: Double(grey.blueComponent)
        )
        #expect(luminance.isLegibleOnAnyMenuBar)
    }

    @Test("Alert state is part of the cache identity")
    func cacheDistinguishesAlerts() {
        MenuBarIconRenderer.invalidateCache()

        let plain = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false
        )
        let alerting = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40), .init(fraction: 70, isAlerting: true)],
            isStale: false
        )

        #expect(plain !== alerting)
    }

    /// Three bars have to fit the same 16pt as two, or the icon shoves its
    /// neighbours along the menu bar.
    @Test("A third bar does not grow the icon")
    func threeBarsKeepTheSameSize() {
        let two = MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false
        )
        let three = MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70), .init(fraction: 90)], isStale: false
        )

        #expect(two.size == MenuBarIconRenderer.size)
        #expect(three.size == MenuBarIconRenderer.size)

        let (barHeight, gap) = MenuBarIconRenderer.geometry(barCount: 3)
        #expect(barHeight * 3 + gap * 2 <= MenuBarIconRenderer.size.height)
    }
}

@Suite("Per-provider reminder rules")
struct ProviderReminderRuleTests {
    /// Codex used to inherit Claude's weekly thresholds, which are tuned for a
    /// different quota entirely.
    @Test("Each window resolves to its own rule")
    func rulesAreIndependent() {
        var settings = AppSettings()
        settings.sessionReminder.leadTimeMinutes = 11
        settings.weeklyReminder.leadTimeMinutes = 22
        settings.codexWeeklyReminder.leadTimeMinutes = 33

        #expect(settings.reminderRule(for: .claudeCode, kind: .session).leadTimeMinutes == 11)
        #expect(settings.reminderRule(for: .claudeCode, kind: .weekly).leadTimeMinutes == 22)
        #expect(settings.reminderRule(for: .codex, kind: .weekly).leadTimeMinutes == 33)
    }

    /// Codex reports no session window; a rule that could fire for one would be
    /// a reminder about something that does not exist.
    @Test("Windows a provider does not report can never fire")
    func unreportedWindowsAreDisabled() {
        let settings = AppSettings()
        #expect(!settings.reminderRule(for: .codex, kind: .session).enabled)
        #expect(!settings.reminderRule(for: .claudeCode, kind: .modelSpecificWeekly).enabled)
    }
}
