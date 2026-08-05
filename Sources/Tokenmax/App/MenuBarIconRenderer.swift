import AppKit

/// Draws the two-meter menubar glyph: top bar is remaining session quota,
/// bottom bar is remaining weekly quota.
///
/// Transparent background, bars matching the other menu bar icons by default,
/// lit in the user's highlight colour while it is a good moment to spend quota.
///
/// The default state is drawn as a **template image**: macOS then tints it to
/// match the menu bar, exactly like the system's own icons. That matters
/// because menu bar contrast follows the *wallpaper*, not the light/dark
/// setting — a colourful desktop gives white icons while the system appearance
/// is still light, so `labelColor` (which resolved to black) was wrong.
///
/// The ready state opts out of templating, since a template would be flattened
/// to a single tint and the colour would be lost. That is also why the glow only
/// exists in the ready state: there is nothing for it to survive in otherwise.
enum MenuBarIconRenderer {
    static let size = NSSize(width: 20, height: 16)

    /// The default "spend it now" colour, kept as a name because the icon tests
    /// and the neutral/ready comparison both want one fixed reference.
    static let readyColor = HighlightColor.default.nsColor

    /// Placeholder for the template mask. Only the alpha matters — macOS
    /// replaces the colour when tinting.
    static let templateColor = NSColor.black

    /// One bar's worth of state.
    struct Bar: Hashable, Sendable {
        /// Percent *remaining*, or nil when unknown.
        var fraction: Double?
        /// This window's reminder has already fired and the window has not reset
        /// yet, so the bar carries the alert colour.
        var isAlerting: Bool
        /// *This* window is in its "spend it now" stretch.
        ///
        /// Per bar, not per icon. It used to be one flag passed to every bar,
        /// which meant a window with four days left was painted "spend it now"
        /// because a different provider's session was about to reset — a bar
        /// reporting a state that was never its own.
        var isReady: Bool

        init(fraction: Double?, isAlerting: Bool = false, isReady: Bool = false) {
            self.fraction = fraction
            self.isAlerting = isAlerting
            self.isReady = isReady
        }
    }

    /// The colour of a bar whose reminder has fired.
    ///
    /// Fixed rather than configurable, and deliberately the same orange the
    /// popover already uses for everything noteworthy — a second colour picker
    /// would let the user set it equal to the highlight colour, at which point
    /// the two signals it exists to separate become one.
    static let alertColor = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.10, alpha: 1)

    /// What an *un*-alerting bar is drawn in once the icon has to abandon
    /// templating to show colour at all.
    ///
    /// A mid grey rather than `labelColor`, for the reason in the type comment:
    /// menu bar contrast follows the wallpaper, so there is no correct answer
    /// available here. Grey is the one value that stays legible against both
    /// ends — it clears `HighlightColor.minimumContrastRatio` on black and on
    /// white, which no near-black or near-white choice does.
    /// sRGB rather than `NSColor(white:)`, which lands in the calibrated-grey
    /// space where the RGB accessors are not valid — the legibility check reads
    /// those components.
    static let untemplatedNeutralColor = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    /// How far the bloom reaches.
    ///
    /// The icon stays *exactly* menu bar sized — padding it out for the glow
    /// would shove the neighbouring items around and misalign the bars against
    /// every other icon in the bar, which is a worse trade than a halo clipped
    /// at the edges. So the glow is tuned to the room that already exists: it
    /// floods the 2.5pt gap between the two bars and the ~1.75pt above and
    /// below them, which is what actually reads as "lit" at this scale.
    static let glowRadius: CGFloat = 2.5

    private struct CacheKey: Hashable {
        /// Percentages rounded to whole numbers, paired with each bar's alert
        /// state — the whole reading, in order.
        let bars: [Bar]
        let isStale: Bool
        /// Nil unless the highlight is actually being drawn, so every unlit
        /// reading shares one cache entry no matter what colour is configured.
        let highlight: HighlightColor?
        let glow: Bool
    }

    /// The status item rasterizes its image more often than it is assigned, so
    /// each distinct reading is drawn once and reused.
    @MainActor private static var imageCache: [CacheKey: NSImage] = [:]

    /// Bar thickness and spacing for a given bar count.
    ///
    /// Three bars have to fit the same 16pt as two — the icon may not grow, or
    /// it shoves its neighbours along the menu bar and misaligns against every
    /// other item. So the third bar is paid for out of thickness and gap rather
    /// than height.
    static func geometry(barCount: Int) -> (barHeight: CGFloat, gap: CGFloat) {
        barCount >= 3 ? (3.5, 1.75) : (5, 2.5)
    }

    static func image(
        bars: [Bar],
        isStale: Bool,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        // Eager, bitmap-backed. `NSImage(size:flipped:drawingHandler:)` would
        // re-run the closure on every rasterization instead of once.
        let image = NSImage(size: size)
        image.lockFocus()

        let (barHeight, gap) = geometry(barCount: bars.count)
        let totalHeight = barHeight * CGFloat(bars.count) + gap * CGFloat(max(0, bars.count - 1))
        let originY = (size.height - totalHeight) / 2

        // A coloured bar cannot survive templating, and a template is the only
        // way the neutral bars can match the menu bar. When both are on screen
        // the colour has to win, so the neutrals fall back to grey.
        let templated = !bars.contains { $0.isReady || $0.isAlerting }

        for (index, bar) in bars.enumerated() {
            // Drawn top-down: the first source is the top bar, matching the
            // order the settings editor shows.
            let rowFromBottom = CGFloat(bars.count - 1 - index)
            draw(
                bar: bar,
                rect: NSRect(
                    x: 0,
                    y: originY + rowFromBottom * (barHeight + gap),
                    width: size.width,
                    height: barHeight
                ),
                isStale: isStale,
                templated: templated,
                highlight: highlight,
                glow: isGlowing(isStale: isStale, isReady: bar.isReady, glow: glow)
            )
        }

        image.unlockFocus()
        image.isTemplate = templated
        return image
    }

    /// A glow is only ever drawn on a lit, trusted icon. Templating would
    /// flatten it away in the neutral state, and stale data must never be
    /// dressed up as an opportunity in the first place.
    static func isGlowing(isStale: Bool, isReady: Bool, glow: Bool) -> Bool {
        glow && isReady && !isStale
    }

    @MainActor
    static func cachedImage(
        bars: [Bar],
        isStale: Bool,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        let lit = bars.contains(where: \.isReady) && !isStale

        // Round to whole percent: the icon cannot show more resolution than
        // that, and it stops the cache growing on every tiny fluctuation.
        let key = CacheKey(
            bars: bars.map {
                Bar(
                    fraction: $0.fraction.map { Double(Int($0.rounded())) },
                    isAlerting: $0.isAlerting,
                    isReady: $0.isReady
                )
            },
            isStale: isStale,
            highlight: lit ? highlight : nil,
            glow: isGlowing(isStale: isStale, isReady: lit, glow: glow)
        )

        if let cached = imageCache[key] { return cached }

        let rendered = image(
            bars: bars,
            isStale: isStale,
            highlight: highlight,
            glow: glow
        )
        // Three bars and three alert states multiply the reachable states, so
        // the cap is above the old 16 to keep the common rotation resident.
        if imageCache.count > 48 { imageCache.removeAll() }
        imageCache[key] = rendered
        return rendered
    }

    /// Discards cached images. Needed when the system appearance flips, since
    /// `labelColor` resolves differently either side of that.
    @MainActor
    static func invalidateCache() {
        imageCache.removeAll()
    }

    private static func draw(
        bar: Bar,
        rect: NSRect,
        isStale: Bool,
        templated: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        let fraction = bar.fraction
        let radius = rect.height / 2
        let color = barColor(
            isStale: isStale,
            isReady: bar.isReady,
            isAlerting: bar.isAlerting,
            templated: templated,
            highlight: highlight
        )

        // Empty track: the bar colour at low alpha, so it reads as "unfilled"
        // rather than as a second colour.
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard let fraction, !isStale else {
            // Stale or unknown: leave the track and add a muted stub so the
            // icon still reads as a set of meters rather than blank slots.
            (templated ? templateColor : untemplatedNeutralColor).withAlphaComponent(0.4).setFill()
            let stub = NSRect(x: rect.minX, y: rect.minY, width: rect.height, height: rect.height)
            NSBezierPath(roundedRect: stub, xRadius: radius, yRadius: radius).fill()
            return
        }

        let clamped = max(0, min(1, fraction / 100))
        guard clamped > 0 else { return }

        // Always render at least a nub so "1% left" is visibly distinct from 0.
        let fillWidth = max(rect.height, rect.width * clamped)
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)

        color.setFill()

        if glow {
            NSGraphicsContext.saveGraphicsState()
            let bloom = NSShadow()
            bloom.shadowColor = color.withAlphaComponent(0.85)
            bloom.shadowBlurRadius = glowRadius
            bloom.shadowOffset = .zero
            bloom.set()
            // Twice: a single pass is barely there at 5pt, and the second
            // compounds because it casts its own shadow over the first's.
            fill.fill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The crisp core goes down last, unshadowed, so the bloom never softens
        // the edge that carries the actual reading.
        fill.fill()
    }

    /// In the templated state this is only a mask — alpha is what survives
    /// templating, and macOS supplies the actual colour.
    ///
    /// The precedence is the point: a fired reminder outranks a burn
    /// opportunity on its own bar, so "you are about to waste this window" is
    /// never repainted by the more general "now is a good time to spend".
    static func barColor(
        isStale: Bool,
        isReady: Bool,
        isAlerting: Bool = false,
        templated: Bool = true,
        highlight: HighlightColor = .default
    ) -> NSColor {
        if isStale { return (templated ? templateColor : untemplatedNeutralColor).withAlphaComponent(0.45) }
        // Ready outranks alerting. "Already notified" is notification
        // bookkeeping, not a statement about quota: a window with 80% left that
        // happens to have been announced is an *opportunity*, and painting it
        // the warning colour contradicted the popover, which was calling the
        // same window a good time to spend. Alert survives for the case it was
        // meant for — a window that has been announced and is genuinely low,
        // which by then is no longer a burn opportunity and so never reaches
        // this branch as ready.
        if isReady { return highlight.nsColor }
        if isAlerting { return alertColor }
        return templated ? templateColor : untemplatedNeutralColor
    }

    /// "3:44", always `hours:minutes` even under an hour ("0:44") — time until
    /// the chosen window resets. A week away reads "6d 18h" instead: a weekly
    /// window would otherwise render as "162:18", which is both wider than the
    /// menu bar wants and unreadable as a duration.
    ///
    /// The bars already carry "how much is left"; what they cannot show is how
    /// long there is to spend it, which is the number that decides whether to
    /// start something now.
    ///
    /// Deliberately terser than `RelativeTime.countdown`, which stays verbose
    /// ("1h 16m") for the popover and notification bodies where there is room.
    /// The menu bar is charged by the pixel.
    /// `nil` when the window is not running, so the label can collapse to the
    /// bars alone rather than reserving width for a placeholder.
    static func countdownText(resetAt: Date?, now: Date) -> String? {
        guard let resetAt else { return nil }

        let interval = resetAt.timeIntervalSince(now)
        guard interval > 0 else { return "0:00" }

        // Truncated, not rounded: "0:44" means *at least* 44 minutes left, which
        // is the safe direction for a deadline.
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        guard hours < 24 else { return "\(hours / 24)d \(hours % 24)h" }
        return "\(hours):\(String(format: "%02d", minutes))"
    }
}
