import AppKit
import Testing

@testable import Tokenmax

@Suite("Menubar icon rendering")
@MainActor
struct MenuBarIconRendererTests {
    private func pixels(_ image: NSImage) -> Data? {
        image.tiffRepresentation
    }

    @Test("The ready state visibly changes what is drawn")
    func readyStateChangesOutput() throws {
        let normal = try #require(pixels(
            MenuBarIconRenderer.image(bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false)
        ))
        let ready = try #require(pixels(
            MenuBarIconRenderer.image(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)
        ))

        #expect(normal != ready)
    }

    @Test("Bars are neutral by default and green when ready")
    func barColours() {
        #expect(MenuBarIconRenderer.barColor(isStale: false, isReady: false) == MenuBarIconRenderer.templateColor)
        #expect(MenuBarIconRenderer.barColor(isStale: false, isReady: true) == MenuBarIconRenderer.readyColor)
    }

    @Test("A configured highlight colour is what actually gets drawn")
    func barColourFollowsSetting() {
        let blue = HighlightColor(red: 0.2, green: 0.6, blue: 1.0)

        #expect(MenuBarIconRenderer.barColor(isStale: false, isReady: true, highlight: blue) == blue.nsColor)
        #expect(MenuBarIconRenderer.barColor(isStale: false, isReady: true, highlight: blue) != MenuBarIconRenderer.readyColor)

        // The unlit icon is a template mask; the colour has no business there.
        #expect(
            MenuBarIconRenderer.barColor(isStale: false, isReady: false, highlight: blue)
                == MenuBarIconRenderer.templateColor
        )
    }

    @Test("Two different highlight colours draw differently")
    func highlightColourChangesOutput() throws {
        let green = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, highlight: .default
        )))
        let pink = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false,
            highlight: HighlightColor(red: 1, green: 0.35, blue: 0.62)
        )))

        #expect(green != pink)
    }

    @Test("The glow visibly changes what is drawn")
    func glowChangesOutput() throws {
        let plain = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, glow: false
        )))
        let glowing = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, glow: true
        )))

        #expect(plain != glowing)
    }

    /// A template image is flattened to a single tint, so a glow drawn into the
    /// neutral icon would be thrown away — and asking for one must not quietly
    /// produce a *different* neutral icon than not asking for one.
    @Test("The glow is confined to the lit state")
    func glowOnlyAppliesWhenReady() throws {
        #expect(!MenuBarIconRenderer.isGlowing(isStale: false, isReady: false, glow: true))
        #expect(MenuBarIconRenderer.isGlowing(isStale: false, isReady: true, glow: true))

        let plain = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false, glow: false
        )))
        let asked = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false, glow: true
        )))

        #expect(plain == asked)
    }

    /// Stale data must never be dressed up as an opportunity — including by
    /// glowing at it.
    @Test("Stale data never glows")
    func staleNeverGlows() throws {
        #expect(!MenuBarIconRenderer.isGlowing(isStale: true, isReady: true, glow: true))

        let plain = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: true, glow: false
        )))
        let glowing = try #require(pixels(MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: true, glow: true
        )))

        #expect(plain == glowing)
    }

    /// Menu bar contrast follows the wallpaper, not the light/dark setting, so
    /// the neutral icon must be a template and let macOS tint it — otherwise it
    /// renders black on a dark menu bar.
    @Test("Neutral icon is a template; the green one is not")
    func templatingFollowsState() {
        let neutral = MenuBarIconRenderer.image(bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false)
        let ready = MenuBarIconRenderer.image(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)

        #expect(neutral.isTemplate)
        #expect(!ready.isTemplate)
    }

    @Test("Stale icon is still a template so it stays legible")
    func staleIsTemplate() {
        let stale = MenuBarIconRenderer.image(bars: [.init(fraction: nil), .init(fraction: nil)], isStale: true)
        #expect(stale.isTemplate)
    }

    /// Stale data must never be dressed up as an opportunity.
    @Test("Stale data is dimmed, never green")
    func staleIsDimmed() {
        let stale = MenuBarIconRenderer.barColor(isStale: true, isReady: true)
        #expect(stale != MenuBarIconRenderer.readyColor)
    }

    /// Padding the icon out to fit the bloom would shove the neighbouring menu
    /// bar items around and misalign the bars against every other icon — and it
    /// would do it only while the highlight happened to be lit. The glow lives
    /// inside the existing bounds instead.
    @Test("Icon is exactly the menubar size — no glow padding")
    func iconSize() {
        let plain = MenuBarIconRenderer.image(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)
        let glowing = MenuBarIconRenderer.image(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, glow: true
        )

        #expect(plain.size == MenuBarIconRenderer.size)
        #expect(glowing.size == MenuBarIconRenderer.size)
    }

    /// The bloom is drawn behind the fill, so the reading itself has to come out
    /// the same width whether or not it is glowing.
    @Test("A full bar still renders at full size with the glow on")
    func glowDoesNotResizeAFullBar() {
        let full = MenuBarIconRenderer.image(
            bars: [.init(fraction: 100, isReady: true), .init(fraction: 100, isReady: true)],
            isStale: false, glow: true
        )
        #expect(full.size == MenuBarIconRenderer.size)
    }

    /// Regression: the icon used to be re-drawn on every render, which
    /// saturated the main thread and beachballed the app.
    @Test("An unchanged reading is drawn once and reused")
    func imagesAreCached() {
        let first = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)
        let second = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)

        // Identical object, not merely equal — proves no re-render happened.
        #expect(first === second)
    }

    @Test("Ready and default states are cached separately")
    func readyAndDefaultAreDistinct() {
        let ready = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false)
        let normal = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false)

        #expect(ready !== normal)
        #expect(ready.tiffRepresentation != normal.tiffRepresentation)
    }

    /// Changing the colour or the glow in Settings has to reach the menu bar,
    /// and the cache is the one thing standing between them.
    @Test("Colour and glow are part of the cache identity")
    func cacheDistinguishesAppearance() {
        MenuBarIconRenderer.invalidateCache()

        let green = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, highlight: .default
        )
        let blue = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false,
            highlight: HighlightColor(red: 0.2, green: 0.6, blue: 1.0)
        )
        let glowing = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)], isStale: false, highlight: .default, glow: true
        )

        #expect(green !== blue)
        #expect(green !== glowing)
    }

    /// An unlit icon looks the same whatever colour is configured, so caching one
    /// entry per colour would just be extra renders and a bigger cache.
    @Test("Unlit readings share one cache entry across colours")
    func cacheIgnoresColourWhenUnlit() {
        MenuBarIconRenderer.invalidateCache()

        let a = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false, highlight: .default, glow: true
        )
        let b = MenuBarIconRenderer.cachedImage(
            bars: [.init(fraction: 40), .init(fraction: 70)], isStale: false,
            highlight: HighlightColor(red: 0.2, green: 0.6, blue: 1.0), glow: false
        )

        #expect(a === b)
    }

    @Test("Sub-percent fluctuations reuse the same cached image")
    func cacheIgnoresSubPercentNoise() {
        let a = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40.2), .init(fraction: 70.1)], isStale: false)
        let b = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 40.4), .init(fraction: 70.3)], isStale: false)

        #expect(a === b)
    }

    /// The bar colour is appearance-dependent, so a cached image outlives its
    /// validity when the user switches between light and dark.
    @Test("Invalidating the cache forces a fresh render")
    func cacheCanBeInvalidated() {
        let first = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 55), .init(fraction: 66)], isStale: false)
        MenuBarIconRenderer.invalidateCache()
        let second = MenuBarIconRenderer.cachedImage(bars: [.init(fraction: 55), .init(fraction: 66)], isStale: false)

        #expect(first !== second)
    }

    /// No window running means there is no countdown to show, and reserving
    /// menu bar width for a placeholder defeats the point of the compact format.
    @Test("No running window yields no label at all")
    func missingResetYieldsNoLabel() {
        #expect(MenuBarIconRenderer.countdownText(resetAt: nil, now: Date()) == nil)
    }

    /// Compact on purpose — this competes with every other menu bar item for
    /// width.
    @Test("An hour or more reads as h:mm")
    func countdownFormatsHoursAndMinutes() {
        let now = Date()

        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(224 * 60), now: now
        ) == "3:44")

        // The minutes are padded so the label does not read as "3:4".
        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(185 * 60), now: now
        ) == "3:05")

        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(60 * 60), now: now
        ) == "1:00")
    }

    @Test("Under an hour still carries the leading 0:")
    func countdownFormatsMinutesOnly() {
        let now = Date()

        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(44 * 60), now: now
        ) == "0:44")

        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(5 * 60), now: now
        ) == "0:05")
    }

    /// Truncated rather than rounded: the label must never promise more time
    /// than is actually left.
    @Test("Partial minutes round down")
    func countdownTruncates() {
        let now = Date()
        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(44 * 60 + 59), now: now
        ) == "0:44")
    }

    /// A window that has already reset must not render a negative countdown
    /// while the next refresh is still in flight.
    @Test("A past reset time clamps to zero")
    func pastResetClampsToZero() {
        let now = Date()
        #expect(MenuBarIconRenderer.countdownText(
            resetAt: now.addingTimeInterval(-60), now: now
        ) == "0:00")
    }
}
