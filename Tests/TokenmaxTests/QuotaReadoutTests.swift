import Foundation
import Testing

@testable import Tokenmax

@Suite("Quota readout: left or used")
struct QuotaReadoutTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func window(remaining: Double, id: String = "claude.session", kind: UsageWindowKind = .session) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: kind,
            label: kind == .session ? "Session" : "Weekly",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(3600),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    private func snapshot(session: Double, weekly: Double) -> UsageSnapshot {
        UsageSnapshot(
            providerID: TokenmaxProvider.claudeCode.rawValue,
            planName: nil,
            windows: [
                window(remaining: session),
                window(remaining: weekly, id: "claude.weekly", kind: .weekly),
            ],
            fetchedAt: now,
            fetchDuration: 0,
            errorMessage: nil
        )
    }

    private func projection(expectedUsed: Double, outlook: UsageOutlook) -> UsageProjection {
        UsageProjection(percentPerHour: 5, expectedUsedPercent: expectedUsed, remainingPercent: 50, outlook: outlook)
    }

    // MARK: - The number

    @Test("Used is the complement of the displayed remaining figure, so the two never disagree by a rounding")
    func usedComplementsRemaining() {
        for remaining in [0, 0.4, 0.51, 12, 87.5, 99.6, 99.99, 100] as [Double] {
            #expect(
                QuotaReadout.used.displayPercent(forRemaining: remaining)
                    == 100 - QuotaReadout.remaining.displayPercent(forRemaining: remaining)
            )
        }
        #expect(QuotaReadout.used.displayPercent(forRemaining: 88) == 12)
    }

    @Test("A window reads 0% used only when untouched, never after a sliver has gone")
    func zeroUsedMeansUntouched() {
        #expect(QuotaReadout.used.displayPercent(forRemaining: 100) == 0)
        #expect(QuotaReadout.used.displayPercent(forRemaining: 99.99) == 1)
        #expect(QuotaReadout.used.displayPercent(forRemaining: 99.6) == 1)
    }

    @Test("A window reads 100% used exactly when it reads Limit reached")
    func fullUsedMatchesExhausted() {
        #expect(QuotaReadout.used.displayPercent(forRemaining: 0.4) == 100)
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 0.4), readout: .used) == "Limit reached")
        #expect(QuotaReadout.used.displayPercent(forRemaining: 0.51) == 99)
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 0.51), readout: .used) == "99% used")
    }

    @Test("Written-out readings name their direction")
    func textNamesDirection() {
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 88), readout: .remaining) == "88% left")
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 88), readout: .used) == "12% used")
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 88)) == "88% left")
    }

    @Test("The menu bar number flips with the setting and stays a dash without a reading")
    func menuBarNumberFlips() {
        #expect(MenuBarIconRenderer.numberText(for: .init(fraction: 88), readout: .used) == "12%")
        #expect(MenuBarIconRenderer.numberText(for: .init(fraction: 88), readout: .remaining) == "88%")
        #expect(MenuBarIconRenderer.numberText(for: .init(fraction: nil), readout: .used) == "--")
    }

    // MARK: - The meter

    @Test("Read as used, an untouched window draws no fill and an exhausted one a full bar")
    func usedFillEnds() {
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 100), isStale: false, readout: .used) == nil)
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 0.4), isStale: false, readout: .used) == 1)
        let quarter = UsageWindowPresentation.fillFraction(for: window(remaining: 75), isStale: false, readout: .used)
        #expect(quarter == 0.25)
    }

    @Test("A stale reading draws nothing in either direction")
    func staleDrawsNothing() {
        for readout in QuotaReadout.allCases {
            #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 40), isStale: true, readout: readout) == nil)
        }
    }

    @Test("Reading as remaining keeps the meter exactly as before")
    func remainingFillUnchanged() {
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 0.4), isStale: false, readout: .remaining) == nil)
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 75), isStale: false, readout: .remaining) == 0.75)
    }

    @Test("The pace marker moves to the other end of a meter that fills")
    func paceMarkerMirrors() {
        let pace = projection(expectedUsed: 30, outlook: .reserve(percent: 20))
        #expect(UsageWindowPresentation.paceMarkerPosition(for: pace, readout: .remaining) == 0.7)
        #expect(abs(UsageWindowPresentation.paceMarkerPosition(for: pace, readout: .used) - 0.3) < 1e-9)
    }

    @Test("The pace marker lands on the fill for a reserve read as left and for a deficit read as used")
    func paceMarkerContrast() {
        let reserve = projection(expectedUsed: 30, outlook: .reserve(percent: 20))
        let deficit = projection(expectedUsed: 30, outlook: .deficit(percent: 20, emptyAt: now))
        #expect(UsageWindowPresentation.paceMarkerIsOnFill(for: reserve, readout: .remaining))
        #expect(!UsageWindowPresentation.paceMarkerIsOnFill(for: deficit, readout: .remaining))
        #expect(UsageWindowPresentation.paceMarkerIsOnFill(for: deficit, readout: .used))
        #expect(!UsageWindowPresentation.paceMarkerIsOnFill(for: reserve, readout: .used))
    }

    @MainActor
    @Test("The same reading drawn either way is two images, so flipping the setting redraws the icon")
    func iconCacheKeysOnReadout() {
        let meters: [MenuBarIconRenderer.Meter] = [.init(fraction: 80), .init(fraction: 30)]
        let left = MenuBarIconRenderer.cachedImage(meters: meters, isStale: false, readout: .remaining)
        let used = MenuBarIconRenderer.cachedImage(meters: meters, isStale: false, readout: .used)
        #expect(left !== used)
        #expect(left.tiffRepresentation != used.tiffRepresentation)
    }

    @Test("A meter read as used at 20% draws the same bar as one read as left at 20%")
    func mirroredReadingsDrawAlike() {
        let left = MenuBarIconRenderer.image(meters: [.init(fraction: 20)], isStale: false, readout: .remaining)
        let used = MenuBarIconRenderer.image(meters: [.init(fraction: 80)], isStale: false, readout: .used)
        #expect(left.tiffRepresentation == used.tiffRepresentation)
    }

    // MARK: - Rules stay in percent remaining

    /// The escalation ladder judges `Meter.fraction`. If the model stored the
    /// flipped figure there, a window with 85% left would trip a "15% left"
    /// level the moment the setting changed.
    @Test("The icon model keeps percent remaining on its meters whichever way it reads")
    func meterFractionStaysRemaining() {
        let claude = snapshot(session: 85, weekly: 40)
        for readout in QuotaReadout.allCases {
            let model = MenuBarIconModel.make(
                layout: .bars(MenuBarBars([.claudeSession, .claudeWeekly])),
                countdownSource: .claudeSession,
                snapshot: { _ in claude },
                isStale: { _ in false },
                alerting: [],
                ready: [],
                readout: readout
            )
            #expect(model.meters.map(\.fraction) == [85, 40])
        }
    }

    @Test("The escalation colour does not change when only the direction does")
    func escalationIgnoresDirection() {
        let lowSession = snapshot(session: 10, weekly: 90)
        let colours = SideNotchColorSettings(scheme: .escalating, escalation: .default)
        func colour(_ readout: QuotaReadout) -> HighlightColor? {
            SideNotchPresentation.make(
                layout: MenuBarRings([.claudeWeekly, .claudeSession]),
                enabledProviders: [.claudeCode],
                snapshot: { _ in lowSession },
                isStale: { _ in false },
                alerting: [],
                ready: [],
                colors: colours,
                readout: readout,
                now: now,
                projection: { _ in nil },
                reminderStatus: { _, _ in nil }
            ).first?.inner.color
        }
        #expect(colour(.remaining) != nil)
        #expect(colour(.used) == colour(.remaining))
    }

    @Test("The tooltip readings spell out the direction and say so when a reading is out of date")
    func readingsSpellOutDirection() {
        let claude = snapshot(session: 88, weekly: 40)
        let model = MenuBarIconModel.make(
            layout: .bars(MenuBarBars([.claudeSession, .claudeWeekly])),
            countdownSource: .claudeSession,
            snapshot: { _ in claude },
            isStale: { _ in false },
            alerting: [],
            ready: [],
            readout: .used
        )
        #expect(model.readings == ["Claude session 12% used", "Claude week 60% used"])

        let stale = MenuBarIconModel.make(
            layout: .bars(MenuBarBars([.claudeSession, .codexWeekly])),
            countdownSource: .claudeSession,
            snapshot: { $0 == .claudeCode ? claude : nil },
            isStale: { $0 == .claudeCode },
            alerting: [],
            ready: [],
            readout: .used
        )
        #expect(stale.readings == ["Claude session reading out of date", "Codex week unknown"])
    }

    @Test("Side Notch's ring and its text follow the direction")
    func sideNotchFollows() throws {
        let claude = snapshot(session: 100, weekly: 40)
        let presentation = try #require(SideNotchPresentation.make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: { _ in claude },
            isStale: { _ in false },
            alerting: [],
            ready: [],
            colors: .init(),
            readout: .used,
            now: now,
            projection: { _ in nil },
            reminderStatus: { _, _ in nil }
        ).first)
        #expect(presentation.outer.percentText == "60%")
        #expect(presentation.outer.readingText == "60% used")
        #expect(presentation.outer.fraction == 0.6)
        // Untouched session, read as used: no fill, so no round-capped dot.
        #expect(presentation.inner.fraction == nil)
        #expect(presentation.inner.readingText == "0% used")
    }
}
