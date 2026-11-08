import AppKit
import Foundation
import Testing

@testable import Tokenmax

@Suite("Menubar numbers layout")
struct MenuBarNumbersTests {
    /// The number was asked for by someone who watches the 5h window alone.
    @Test("The default is the Claude session by itself")
    func defaultLayout() {
        #expect(MenuBarNumbers.default.sources == [.claudeSession])
    }

    /// Bars pad up to two; a single number is the point of this style.
    @Test("One number is a complete layout and is not padded to two")
    func oneIsEnough() {
        #expect(MenuBarNumbers([.codexWeekly]).sources == [.codexWeekly])
    }

    @Test("Two numbers are the ceiling")
    func twoIsTheCeiling() {
        #expect(MenuBarNumbers(MenuBarQuotaSource.allCases).count == MenuBarNumbers.maximumCount)
    }

    @Test("Duplicates are collapsed rather than drawn twice")
    func duplicatesCollapse() {
        #expect(MenuBarNumbers([.claudeWeekly, .claudeWeekly]).sources == [.claudeWeekly])
    }

    @Test("An empty layout is padded, because a menu bar item with no number is unclickable")
    func emptyIsPadded() {
        #expect(MenuBarNumbers([]).count == 1)
    }

    @Test("A disabled provider's quota is dropped from what is drawn")
    func disabledProviderIsDropped() {
        let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]
        let numbers = MenuBarNumbers([.codexSession, .claudeWeekly], allowed: claudeOnly)
        #expect(numbers.sources == [.claudeWeekly])
    }

    @Test("Growing adds the first unused quota and shrinking drops the lower number")
    func resizing() {
        let one = MenuBarNumbers([.claudeWeekly])
        #expect(one.resized(to: 2).sources == [.claudeWeekly, .claudeSession])
        #expect(MenuBarNumbers([.claudeWeekly, .claudeSession]).resized(to: 1).sources == [.claudeWeekly])
    }

    @Test("Dropping a placed quota onto another number swaps them")
    func dropSwaps() {
        let numbers = MenuBarNumbers([.claudeSession, .claudeWeekly])
        #expect(numbers.replacing(at: 0, with: .claudeWeekly).sources == [.claudeWeekly, .claudeSession])
    }

    @Test("A drop of a disabled provider's quota is refused")
    func disabledDropIsRefused() {
        let claudeOnly: [MenuBarQuotaSource] = [.claudeSession, .claudeWeekly]
        let numbers = MenuBarNumbers([.claudeSession], allowed: claudeOnly)
        #expect(numbers.replacing(at: 0, with: .codexSession, allowed: claudeOnly) == numbers)
    }

    @Test("The Numbers style resolves to its own layout, and keeps the others' on disk")
    func settingsResolveTheLayout() {
        var settings = AppSettings()
        settings.menuBarIconStyle = .numbers
        settings.menuBarNumbers = MenuBarNumbers([.claudeWeekly, .claudeSession])

        #expect(settings.effectiveMenuBarLayout.style == .numbers)
        #expect(settings.effectiveMenuBarLayout.sources == [.claudeWeekly, .claudeSession])
        #expect(settings.menuBarBars == .default)
        #expect(settings.menuBarRings == .default)
    }

    @Test("A provider's own item writes its session over its week")
    func providerItemShowsBothWindows() {
        let layout = MenuBarItemDecision.layout(for: .codex, style: .numbers)
        #expect(layout.style == .numbers)
        #expect(layout.sources == [.codexSession, .codexWeekly])
    }
}

@Suite("Menubar numbers drawing")
struct MenuBarNumbersRenderingTests {
    private func meter(_ fraction: Double?) -> MenuBarIconRenderer.Meter { .init(fraction: fraction) }

    @Test("A reading is written as a whole percent")
    func textRoundsToWholePercent() {
        #expect(MenuBarIconRenderer.numberText(for: meter(90)) == "90%")
        #expect(MenuBarIconRenderer.numberText(for: meter(89.6)) == "90%")
        #expect(MenuBarIconRenderer.numberText(for: meter(0)) == "0%")
    }

    @Test("A reading outside 0...100 is clamped, not printed")
    func textIsClamped() {
        #expect(MenuBarIconRenderer.numberText(for: meter(104)) == "100%")
        #expect(MenuBarIconRenderer.numberText(for: meter(-3)) == "0%")
    }

    /// A stale provider's fraction is nil by the time it reaches the renderer.
    /// Printing a number there would be the lie the bars refuse to draw.
    @Test("An unknown reading is a placeholder, never a number")
    func unknownIsAPlaceholder() {
        #expect(MenuBarIconRenderer.numberText(for: meter(nil)) == "--")
    }

    @Test("The icon is exactly the size it declares, at the menu bar's height")
    func iconIsItsDeclaredSize() {
        for readings in [[meter(90)], [meter(90), meter(100)], [meter(nil), meter(7)]] {
            let image = MenuBarIconRenderer.image(style: .numbers, meters: readings, isStale: false)
            #expect(image.size == MenuBarIconRenderer.size(
                style: .numbers, meterCount: readings.count, meters: readings
            ))
            #expect(image.size.height == MenuBarIconRenderer.barsSize.height)
        }
    }

    /// Width follows what is written, so a lone "9%" does not reserve room for
    /// "100%" beside its neighbours — and the widest reading governs.
    @Test("A wider reading makes a wider icon")
    func widthFollowsTheText() {
        let narrow = MenuBarIconRenderer.size(style: .numbers, meterCount: 1, meters: [meter(9)])
        let wide = MenuBarIconRenderer.size(style: .numbers, meterCount: 1, meters: [meter(100)])
        #expect(narrow.width < wide.width)
    }

    @Test("Two lines fit the height the bars use, in a smaller face than one line")
    func twoLinesAreSmaller() {
        #expect(MenuBarIconRenderer.numberFont(count: 2).pointSize < MenuBarIconRenderer.numberFont(count: 1).pointSize)
        // Two rows of cap height, and some air between them.
        #expect(MenuBarIconRenderer.numberFont(count: 2).capHeight * 2 < MenuBarIconRenderer.barsSize.height)
    }

    @Test("Different readings draw differently")
    func readingsChangeThePicture() {
        let a = MenuBarIconRenderer.image(style: .numbers, meters: [meter(90)], isStale: false)
        let b = MenuBarIconRenderer.image(style: .numbers, meters: [meter(40)], isStale: false)
        #expect(a.tiffRepresentation != b.tiffRepresentation)
    }

    /// Nothing drawn would be a blank, unclickable status item.
    @Test("A number actually puts ink on the canvas")
    func drawsSomething() throws {
        let image = MenuBarIconRenderer.image(style: .numbers, meters: [meter(90)], isStale: false)
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        var inked = false
        for x in 0 ..< rep.pixelsWide where !inked {
            for y in 0 ..< rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked = true
                break
            }
        }
        #expect(inked)
    }

    @Test("A neutral reading is a template image, so macOS tints it like the system's own")
    func neutralIsTemplated() {
        let image = MenuBarIconRenderer.image(style: .numbers, meters: [meter(90)], isStale: false)
        #expect(image.isTemplate)
    }

    @Test("The cache does not hand a bar icon to the Numbers style")
    @MainActor
    func cacheSeparatesStyles() {
        MenuBarIconRenderer.invalidateCache()
        let readings = [meter(90), meter(40)]
        let bars = MenuBarIconRenderer.cachedImage(style: .bars, meters: readings, isStale: false)
        let numbers = MenuBarIconRenderer.cachedImage(style: .numbers, meters: readings, isStale: false)
        #expect(bars.size != numbers.size)
    }
}
