import Foundation
import Testing

@testable import Tokenmax

@Suite("Displayed remaining percentage")
struct DisplayPercentTests {
    private let now = Date(timeIntervalSince1970: 1_785_500_000)

    private func window(remaining: Double) -> UsageWindow {
        UsageWindow(
            id: "claude.session",
            kind: .session,
            label: "Session",
            usedPercent: 100 - remaining,
            resetAt: now.addingTimeInterval(3600),
            observedAt: now,
            source: .claudeOAuth,
            confidence: .authoritative
        )
    }

    @Test("A window that is not entirely full never reads 100%")
    func neverRoundsUpToFull() {
        #expect(UsageWindow.displayPercent(forRemaining: 100) == 100)
        #expect(UsageWindow.displayPercent(forRemaining: 99.99) == 99)
        #expect(UsageWindow.displayPercent(forRemaining: 99.5) == 99)
        #expect(UsageWindow.displayPercent(forRemaining: 99.4) == 99)
        #expect(UsageWindow.displayPercent(forRemaining: 98.6) == 99)
    }

    @Test("The percentage is 0 exactly when the window is exhausted, never a lone 1%")
    func zeroMatchesExhausted() {
        for remaining in [0, 0.2, 0.5] as [Double] {
            #expect(window(remaining: remaining).isExhausted)
            #expect(UsageWindow.displayPercent(forRemaining: remaining) == 0)
        }
        #expect(!window(remaining: 0.51).isExhausted)
        #expect(UsageWindow.displayPercent(forRemaining: 0.51) == 1)
    }

    @Test("Out-of-range readings clamp instead of printing nonsense")
    func clamps() {
        #expect(UsageWindow.displayPercent(forRemaining: -4) == 0)
        #expect(UsageWindow.displayPercent(forRemaining: 140) == 100)
    }

    @Test("The popover, the menu bar numbers and the exhausted state agree on a half percent")
    func surfacesAgree() {
        let half = window(remaining: 0.5)
        #expect(UsageWindowPresentation.remainingText(for: half) == "Limit reached")
        #expect(MenuBarIconRenderer.numberText(for: .init(fraction: 0.5)) == "0%")
        #expect(UsageWindowPresentation.remainingText(for: window(remaining: 99.7)) == "99% left")
        #expect(MenuBarIconRenderer.numberText(for: .init(fraction: 99.7)) == "99%")
    }

    @Test("An exhausted window has no fill to draw, so no bar draws a nub for it")
    func exhaustedHasNoFill() {
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 0), isStale: false) == nil)
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 0.4), isStale: false) == nil)
        #expect(UsageWindowPresentation.fillFraction(for: window(remaining: 1), isStale: false) != nil)
    }

    @MainActor
    @Test("The icon cache keys on what is drawn, so 0 and 0.4 share an image and 99.7 and 100 do not")
    func cacheKeyMatchesTheDrawing() {
        func png(_ fraction: Double) -> Data? {
            MenuBarIconRenderer.image(meters: [.init(fraction: fraction)], isStale: false).tiffRepresentation
        }
        #expect(png(0) == png(0.4))
        #expect(png(99.7) != png(100))

        let zero = MenuBarIconRenderer.cachedImage(meters: [.init(fraction: 0)], isStale: false)
        let nearZero = MenuBarIconRenderer.cachedImage(meters: [.init(fraction: 0.4)], isStale: false)
        #expect(zero === nearZero)
    }
}
