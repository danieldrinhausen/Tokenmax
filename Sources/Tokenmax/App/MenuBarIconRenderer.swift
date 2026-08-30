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
    /// The canvas the stacked bars are drawn into. Unchanged since the first
    /// build: 16pt is the menu bar's height budget, and 20pt of width is what
    /// makes a 1% fill still legible as a fraction of the whole.
    static let barsSize = NSSize(width: 20, height: 16)

    /// Ring metrics, in points.
    ///
    /// An arc has to close to read as a meter, so a ring costs its own diameter
    /// instead of sharing the icon's full width the way a bar does. Two rings
    /// therefore spend 35pt where two bars spend 20 — the trade that buys four
    /// quotas in one icon.
    enum Ring {
        /// Height is still the hard constraint: `outerRadius + strokeWidth / 2`
        /// must stay inside `barsSize.height / 2`, or the icon grows and shoves
        /// its neighbours along the menu bar.
        static let strokeWidth: CGFloat = 2.2
        static let outerRadius: CGFloat = 6.6
        /// Leaves 1pt of ground between the two arcs — any less and they read
        /// as one thick band at menu bar size — and a 4.6pt hole at the centre.
        /// The hole is what the stroke width is really spent on: at 2.4pt of
        /// stroke the inner arc closed up into a dot at 100%, which is the one
        /// reading it most needs to distinguish from a nearly full one.
        static let innerRadius: CGFloat = 3.4
        /// One ring's square cell, so a lone ring sits centred rather than
        /// hugging the left edge.
        static let cell: CGFloat = 16
        static let gap: CGFloat = 3
        /// The outer arc carries the longer window, which is context rather
        /// than the thing being spent right now. Dimming it is what makes the
        /// pair read as nested instead of as two equal circles — and alpha is
        /// the one channel that survives templating, which a second colour
        /// would not.
        static let outerAlpha: CGFloat = 0.55
    }

    /// The canvas for `meterCount` meters in the given style.
    static func size(style: MenuBarIconStyle, meterCount: Int) -> NSSize {
        switch style {
        case .bars:
            return barsSize
        case .rings:
            let rings = max(1, meterCount / 2)
            let width = CGFloat(rings) * Ring.cell + CGFloat(rings - 1) * Ring.gap
            return NSSize(width: width, height: barsSize.height)
        }
    }

    /// The default "spend it now" colour, kept as a name because the icon tests
    /// and the neutral/ready comparison both want one fixed reference.
    static let readyColor = HighlightColor.default.nsColor

    /// Placeholder for the template mask. Only the alpha matters — macOS
    /// replaces the colour when tinting.
    static let templateColor = NSColor.black

    /// One meter's worth of state.
    ///
    /// A reading, not a shape: the same values are drawn as a capsule or as an
    /// arc depending on the configured style.
    struct Meter: Hashable, Sendable {
        /// Percent *remaining*, or nil when unknown.
        var fraction: Double?
        /// This window's reminder has already fired and the window has not reset
        /// yet, so the meter carries the alert colour.
        var isAlerting: Bool
        /// *This* window is in its "spend it now" stretch.
        ///
        /// Per meter, not per icon. It used to be one flag passed to every
        /// meter, which meant a window with four days left was painted "spend it
        /// now" because a different provider's session was about to reset — a
        /// meter reporting a state that was never its own.
        var isReady: Bool

        init(fraction: Double?, isAlerting: Bool = false, isReady: Bool = false) {
            self.fraction = fraction
            self.isAlerting = isAlerting
            self.isReady = isReady
        }
    }

    /// The colour of a meter whose reminder has fired.
    ///
    /// Fixed rather than configurable, and deliberately the same orange the
    /// popover already uses for everything noteworthy — a second colour picker
    /// would let the user set it equal to the highlight colour, at which point
    /// the two signals it exists to separate become one.
    static let alertColor = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.10, alpha: 1)

    /// What an *un*-alerting meter is drawn in once the icon has to abandon
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
        /// Two styles draw the same reading differently, so the style is part
        /// of the identity. Without it, switching styles in Settings leaves the
        /// old icon on screen until something else happens to change.
        let style: MenuBarIconStyle
        /// Percentages rounded to whole numbers, paired with each meter's
        /// alert state — the whole reading, in order.
        let meters: [Meter]
        let isStale: Bool
        /// Nil unless the highlight is actually being drawn, so every unlit
        /// reading shares one cache entry no matter what colour is configured.
        let highlight: HighlightColor?
        let glow: Bool
    }

    /// The status item rasterizes its image more often than it is assigned, so
    /// each distinct reading is drawn once and reused.
    @MainActor private static var imageCache: [CacheKey: NSImage] = [:]

    /// Bar thickness and spacing for a given meter count. Bars only; the ring
    /// metrics are fixed and live in `Ring`.
    ///
    /// Three bars have to fit the same 16pt as two — the icon may not grow, or
    /// it shoves its neighbours along the menu bar and misaligns against every
    /// other item. So the third bar is paid for out of thickness and gap rather
    /// than height.
    static func geometry(meterCount: Int) -> (barHeight: CGFloat, gap: CGFloat) {
        meterCount >= 3 ? (3.5, 1.75) : (5, 2.5)
    }

    static func image(
        style: MenuBarIconStyle = .bars,
        meters: [Meter],
        isStale: Bool,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        let canvas = size(style: style, meterCount: meters.count)

        // Eager, bitmap-backed. `NSImage(size:flipped:drawingHandler:)` would
        // re-run the closure on every rasterization instead of once.
        let image = NSImage(size: canvas)
        image.lockFocus()

        // A coloured meter cannot survive templating, and a template is the only
        // way the neutral meters can match the menu bar. When both are on screen
        // the colour has to win, so the neutrals fall back to grey.
        let templated = !meters.contains { $0.isReady || $0.isAlerting }

        switch style {
        case .bars:
            drawBars(meters, in: canvas, isStale: isStale, templated: templated, highlight: highlight, glow: glow)
        case .rings:
            drawRings(meters, in: canvas, isStale: isStale, templated: templated, highlight: highlight, glow: glow)
        }

        image.unlockFocus()
        image.isTemplate = templated
        return image
    }

    private static func drawBars(
        _ meters: [Meter],
        in canvas: NSSize,
        isStale: Bool,
        templated: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        let (barHeight, gap) = geometry(meterCount: meters.count)
        let totalHeight = barHeight * CGFloat(meters.count) + gap * CGFloat(max(0, meters.count - 1))
        let originY = (canvas.height - totalHeight) / 2

        for (index, meter) in meters.enumerated() {
            // Drawn top-down: the first source is the top bar, matching the
            // order the settings editor shows.
            let rowFromBottom = CGFloat(meters.count - 1 - index)
            draw(
                meter: meter,
                rect: NSRect(
                    x: 0,
                    y: originY + rowFromBottom * (barHeight + gap),
                    width: canvas.width,
                    height: barHeight
                ),
                isStale: isStale,
                templated: templated,
                highlight: highlight,
                glow: isGlowing(isStale: isStale, isReady: meter.isReady, glow: glow)
            )
        }
    }

    /// Meters in pairs, outer arc then inner, ring by ring from the left. An
    /// odd trailing meter cannot happen — `MenuBarRings` guarantees an even
    /// count — but it is drawn as a lone outer arc rather than dropped, because
    /// silently rendering nothing is the worse failure in a menu bar item.
    private static func drawRings(
        _ meters: [Meter],
        in canvas: NSSize,
        isStale: Bool,
        templated: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        for (index, meter) in meters.enumerated() {
            let ring = index / 2
            let isOuter = index % 2 == 0
            let centre = NSPoint(
                x: CGFloat(ring) * (Ring.cell + Ring.gap) + Ring.cell / 2,
                y: canvas.height / 2
            )
            draw(
                meter: meter,
                centre: centre,
                radius: isOuter ? Ring.outerRadius : Ring.innerRadius,
                // The dim is hierarchy, not a state, so it applies only while
                // the arc has nothing to announce. A ring that is lit or
                // alerting draws at full strength: muting a signal that exists
                // precisely to be noticed would be the wrong way round.
                dimmed: isOuter && !meter.isReady && !meter.isAlerting,
                isStale: isStale,
                templated: templated,
                highlight: highlight,
                glow: isGlowing(isStale: isStale, isReady: meter.isReady, glow: glow)
            )
        }
    }

    /// A glow is only ever drawn on a lit, trusted icon. Templating would
    /// flatten it away in the neutral state, and stale data must never be
    /// dressed up as an opportunity in the first place.
    static func isGlowing(isStale: Bool, isReady: Bool, glow: Bool) -> Bool {
        glow && isReady && !isStale
    }

    @MainActor
    static func cachedImage(
        style: MenuBarIconStyle = .bars,
        meters: [Meter],
        isStale: Bool,
        highlight: HighlightColor = .default,
        glow: Bool = false
    ) -> NSImage {
        let lit = meters.contains(where: \.isReady) && !isStale

        // Round to whole percent: the icon cannot show more resolution than
        // that, and it stops the cache growing on every tiny fluctuation.
        let key = CacheKey(
            style: style,
            meters: meters.map {
                Meter(
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
            style: style,
            meters: meters,
            isStale: isStale,
            highlight: highlight,
            glow: glow
        )
        // Three bars, three alert states and now two styles multiply the
        // reachable states, so the cap is well above the old 16 to keep the
        // common rotation resident.
        if imageCache.count > 64 { imageCache.removeAll() }
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
        meter: Meter,
        rect: NSRect,
        isStale: Bool,
        templated: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        let fraction = meter.fraction
        let radius = rect.height / 2
        let color = meterColor(
            isStale: isStale,
            isReady: meter.isReady,
            isAlerting: meter.isAlerting,
            templated: templated,
            highlight: highlight
        )

        // Empty track: the meter colour at low alpha, so it reads as "unfilled"
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

    /// One arc. The ring counterpart of `draw(meter:rect:…)`, and deliberately
    /// the same decisions in polar form: a track at the same low alpha, a
    /// minimum stub so 1% is not 0%, the same stale fallback, the same
    /// two-pass bloom under an unshadowed core.
    private static func draw(
        meter: Meter,
        centre: NSPoint,
        radius: CGFloat,
        dimmed: Bool,
        isStale: Bool,
        templated: Bool,
        highlight: HighlightColor,
        glow: Bool
    ) {
        let base = meterColor(
            isStale: isStale,
            isReady: meter.isReady,
            isAlerting: meter.isAlerting,
            templated: templated,
            highlight: highlight
        )
        // Multiplied into whatever alpha the colour already carries, never
        // assigned over it: `meterColor` mutes a stale reading to 0.45, and
        // replacing that would draw unreadable data at full strength.
        let color = base.withAlphaComponent(base.alphaComponent * (dimmed ? Ring.outerAlpha : 1))

        // Empty track: the meter colour at low alpha, so it reads as "unfilled"
        // rather than as a second colour.
        color.withAlphaComponent(color.alphaComponent * 0.25).setStroke()
        arc(centre: centre, radius: radius, sweep: 1).stroke()

        // The stroke is round-capped, so the shortest arc that still draws is
        // one cap's worth. Below that a fill would vanish entirely, which is
        // the same reason the bar keeps a nub.
        let circumference = 2 * .pi * radius
        let minimumSweep = Ring.strokeWidth / circumference

        guard let fraction = meter.fraction, !isStale else {
            // Stale or unknown: leave the track and add a muted stub so the
            // icon still reads as a set of meters rather than blank slots.
            (templated ? templateColor : untemplatedNeutralColor).withAlphaComponent(0.4).setStroke()
            arc(centre: centre, radius: radius, sweep: minimumSweep).stroke()
            return
        }

        let clamped = max(0, min(1, fraction / 100))
        guard clamped > 0 else { return }

        let fill = arc(centre: centre, radius: radius, sweep: max(minimumSweep, clamped))
        color.setStroke()

        if glow {
            NSGraphicsContext.saveGraphicsState()
            let bloom = NSShadow()
            bloom.shadowColor = color.withAlphaComponent(0.85)
            bloom.shadowBlurRadius = glowRadius
            bloom.shadowOffset = .zero
            bloom.set()
            // Twice, for the reason given on the bar: one pass is barely there
            // at this stroke width, and the second compounds because it casts
            // its own shadow over the first's.
            fill.stroke()
            fill.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // The crisp core goes down last, unshadowed, so the bloom never softens
        // the edge that carries the actual reading.
        fill.stroke()
    }

    /// A round-capped arc of `sweep` (0...1) starting at twelve o'clock and
    /// running clockwise — the direction a meter is read, and the same "starts
    /// full, empties as you spend" reading the bar gives by filling from the
    /// left.
    private static func arc(centre: NSPoint, radius: CGFloat, sweep: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = Ring.strokeWidth
        path.lineCapStyle = .round
        path.appendArc(
            withCenter: centre,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * min(1, sweep),
            clockwise: true
        )
        return path
    }

    /// In the templated state this is only a mask — alpha is what survives
    /// templating, and macOS supplies the actual colour.
    ///
    /// The precedence is the point: a fired reminder outranks a burn
    /// opportunity on its own meter, so "you are about to waste this window" is
    /// never repainted by the more general "now is a good time to spend".
    static func meterColor(
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
