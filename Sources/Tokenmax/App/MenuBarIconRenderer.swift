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
        let session: Int?
        let weekly: Int?
        let isStale: Bool
        let isReady: Bool
        /// Nil unless the highlight is actually being drawn, so every unlit
        /// reading shares one cache entry no matter what colour is configured.
        let highlight: HighlightColor?
        let glow: Bool
    }

    /// The status item rasterizes its image more often than it is assigned, so
    /// each distinct reading is drawn once and reused.
    @MainActor private static var imageCache: [CacheKey: NSImage] = [:]

    static func image(
        session: Double?,
        weekly: Double?,
        isStale: Bool,
        isReady: Bool = false,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        // Eager, bitmap-backed. `NSImage(size:flipped:drawingHandler:)` would
        // re-run the closure on every rasterization instead of once.
        let image = NSImage(size: size)
        image.lockFocus()

        let barHeight: CGFloat = 5
        let gap: CGFloat = 2.5
        let totalHeight = barHeight * 2 + gap
        let originY = (size.height - totalHeight) / 2

        draw(
            fraction: session,
            rect: NSRect(x: 0, y: originY + barHeight + gap, width: size.width, height: barHeight),
            isStale: isStale,
            isReady: isReady,
            highlight: highlight,
            glow: isGlowing(isStale: isStale, isReady: isReady, glow: glow)
        )
        draw(
            fraction: weekly,
            rect: NSRect(x: 0, y: originY, width: size.width, height: barHeight),
            isStale: isStale,
            isReady: isReady,
            highlight: highlight,
            glow: isGlowing(isStale: isStale, isReady: isReady, glow: glow)
        )

        image.unlockFocus()
        // Template only when neutral; the ready state carries its own colour.
        image.isTemplate = !isReady
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
        session: Double?,
        weekly: Double?,
        isStale: Bool,
        isReady: Bool,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        let lit = isReady && !isStale

        // Round to whole percent: the icon cannot show more resolution than
        // that, and it stops the cache growing on every tiny fluctuation.
        let key = CacheKey(
            session: session.map { Int($0.rounded()) },
            weekly: weekly.map { Int($0.rounded()) },
            isStale: isStale,
            isReady: isReady,
            highlight: lit ? highlight : nil,
            glow: isGlowing(isStale: isStale, isReady: isReady, glow: glow)
        )

        if let cached = imageCache[key] { return cached }

        let rendered = image(
            session: session,
            weekly: weekly,
            isStale: isStale,
            isReady: isReady,
            highlight: highlight,
            glow: glow
        )
        if imageCache.count > 16 { imageCache.removeAll() }
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
        fraction: Double?,
        rect: NSRect,
        isStale: Bool,
        isReady: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        let radius = rect.height / 2
        let color = barColor(isStale: isStale, isReady: isReady, highlight: highlight)

        // Empty track: the bar colour at low alpha, so it reads as "unfilled"
        // rather than as a second colour.
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard let fraction, !isStale else {
            // Stale or unknown: leave the track and add a muted stub so the
            // icon still reads as "two meters" rather than two blank slots.
            templateColor.withAlphaComponent(0.4).setFill()
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

    /// In the neutral state this is only a mask — alpha is what survives
    /// templating, and macOS supplies the actual colour.
    static func barColor(isStale: Bool, isReady: Bool, highlight: HighlightColor = .default) -> NSColor {
        if isStale { return templateColor.withAlphaComponent(0.45) }
        return isReady ? highlight.nsColor : templateColor
    }

    /// "3:44", always `hours:minutes` even under an hour ("0:44") — time until
    /// the session window resets.
    ///
    /// The bars already carry "how much is left"; what they cannot show is how
    /// long there is to spend it, which is the number that decides whether to
    /// start something now.
    ///
    /// Deliberately terser than `RelativeTime.countdown`, which stays verbose
    /// ("1h 16m") for the popover and notification bodies where there is room.
    /// The menu bar is charged by the pixel.
    /// `nil` when no session window is running, so the label can collapse to
    /// the bars alone rather than reserving width for a placeholder.
    static func countdownText(sessionResetAt: Date?, now: Date) -> String? {
        guard let sessionResetAt else { return nil }

        let interval = sessionResetAt.timeIntervalSince(now)
        guard interval > 0 else { return "0:00" }

        // Truncated, not rounded: "0:44" means *at least* 44 minutes left, which
        // is the safe direction for a deadline.
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        return "\(hours):\(String(format: "%02d", minutes))"
    }
}
