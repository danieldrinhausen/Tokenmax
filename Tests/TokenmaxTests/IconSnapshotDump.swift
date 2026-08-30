import AppKit
import Testing

@testable import Tokenmax

/// Renders the menubar glyph the way it is actually seen — at true size, on a
/// menubar-like backdrop, lit beside unlit. Visual-only.
@Suite("Icon snapshot dump")
@MainActor
struct IconSnapshotDump {
    /// Side-by-side comparison at a given zoom, on a given backdrop.
    private func comparison(scale: CGFloat, background: NSColor, label: String) -> NSImage {
        // `labelColor` resolves against the *current* appearance, so the dump
        // has to adopt the appearance it is illustrating or it lies.
        // `brightnessComponent` is an HSB accessor and raises on a grayscale
        // colour, which is exactly what the callers pass. Convert first.
        let brightness = background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.5
        let appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)!
        var unlit = NSImage()
        var lit = NSImage()
        appearance.performAsCurrentDrawingAppearance {
            unlit = MenuBarIconRenderer.image(
                meters: [.init(fraction: 40), .init(fraction: 70)], isStale: false
            )
            lit = MenuBarIconRenderer.image(
                meters: [.init(fraction: 40, isReady: true), .init(fraction: 70, isReady: true)],
                isStale: false
            )
        }

        let pad: CGFloat = 12 * scale
        let iconSize = NSSize(width: unlit.size.width * scale, height: unlit.size.height * scale)
        let total = NSSize(
            width: pad * 3 + iconSize.width * 2,
            height: iconSize.height + pad * 2
        )

        let output = NSImage(size: total)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = scale > 3 ? .none : .high

        background.setFill()
        NSRect(origin: .zero, size: total).fill()

        unlit.draw(in: NSRect(
            x: pad, y: pad, width: iconSize.width, height: iconSize.height
        ))
        lit.draw(in: NSRect(
            x: pad * 2 + iconSize.width, y: pad, width: iconSize.width, height: iconSize.height
        ))

        output.unlockFocus()
        _ = label
        return output
    }

    private func write(_ image: NSImage, to name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/tokenmax-icons")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            Issue.record("could not encode \(name)")
            return
        }
        try png.write(to: directory.appendingPathComponent(name))
    }

    /// The layouts and states that only exist since the bars became
    /// configurable: three bars in the same 16pt, and a single alerting bar
    /// beside neutral ones (the case that forces the icon out of templating).
    private func layouts(scale: CGFloat, background: NSColor) -> NSImage {
        let brightness = background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.5
        let appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)!

        var rendered: [NSImage] = []
        appearance.performAsCurrentDrawingAppearance {
            rendered = [
                // Two bars, neutral — the shipping default.
                MenuBarIconRenderer.image(meters: [.init(fraction: 40), .init(fraction: 70)], isStale: false),
                // Three bars, neutral.
                MenuBarIconRenderer.image(
                    meters: [.init(fraction: 40), .init(fraction: 70), .init(fraction: 90)], isStale: false
                ),
                // Three bars, middle one alerting: neutrals fall back to grey.
                MenuBarIconRenderer.image(
                    meters: [
                        .init(fraction: 40),
                        .init(fraction: 70, isAlerting: true),
                        .init(fraction: 90),
                    ],
                    isStale: false
                ),
                // Alerting *and* a burn opportunity on the same bar: the
                // highlight wins there, while a bar that is only alerting keeps
                // the alert colour and an ordinary bar stays neutral.
                MenuBarIconRenderer.image(
                    meters: [
                        .init(fraction: 40, isReady: true),
                        .init(fraction: 70, isAlerting: true),
                        .init(fraction: 90),
                    ],
                    isStale: false
                ),
            ]
        }

        let pad: CGFloat = 12 * scale
        let iconSize = NSSize(
            width: MenuBarIconRenderer.barsSize.width * scale,
            height: MenuBarIconRenderer.barsSize.height * scale
        )
        let total = NSSize(
            width: pad * CGFloat(rendered.count + 1) + iconSize.width * CGFloat(rendered.count),
            height: iconSize.height + pad * 2
        )

        let output = NSImage(size: total)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = scale > 3 ? .none : .high
        background.setFill()
        NSRect(origin: .zero, size: total).fill()

        for (index, image) in rendered.enumerated() {
            image.draw(in: NSRect(
                x: pad * CGFloat(index + 1) + iconSize.width * CGFloat(index),
                y: pad,
                width: iconSize.width,
                height: iconSize.height
            ))
        }
        output.unlockFocus()
        return output
    }

    /// The ring style at the sizes it is actually judged at. Every state that
    /// has its own geometry rule: one ring and two, the dimmed outer arc, a
    /// nearly-spent window against an empty one, and an unreadable stub.
    private func rings(scale: CGFloat, background: NSColor) -> NSImage {
        let brightness = background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.5
        let appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)!

        var rendered: [NSImage] = []
        appearance.performAsCurrentDrawingAppearance {
            rendered = [
                // One ring: outer week, inner session.
                MenuBarIconRenderer.image(
                    style: .rings, meters: [.init(fraction: 39), .init(fraction: 100)], isStale: false
                ),
                // Two rings — the reading from the mockup: Claude week 39 and
                // session 100, Codex week 74 and session 39.
                MenuBarIconRenderer.image(
                    style: .rings,
                    meters: [
                        .init(fraction: 39), .init(fraction: 100),
                        .init(fraction: 74), .init(fraction: 39),
                    ],
                    isStale: false
                ),
                // 1% against 0%: the arc that has to survive the round cap.
                MenuBarIconRenderer.image(
                    style: .rings, meters: [.init(fraction: 1), .init(fraction: 0)], isStale: false
                ),
                // Lit: the outer arc drops its dim, which is the rule worth
                // seeing rather than reading.
                MenuBarIconRenderer.image(
                    style: .rings,
                    meters: [.init(fraction: 62, isReady: true), .init(fraction: 78, isReady: true)],
                    isStale: false
                ),
                // Alerting inner arc beside a neutral outer one.
                MenuBarIconRenderer.image(
                    style: .rings,
                    meters: [.init(fraction: 62), .init(fraction: 12, isAlerting: true)],
                    isStale: false
                ),
                // Unreadable: track plus stub, in both arcs.
                MenuBarIconRenderer.image(
                    style: .rings, meters: [.init(fraction: nil), .init(fraction: nil)], isStale: true
                ),
            ]
        }

        let pad: CGFloat = 12 * scale
        let height = MenuBarIconRenderer.barsSize.height * scale
        let widths = rendered.map { $0.size.width * scale }
        let total = NSSize(
            width: pad * CGFloat(rendered.count + 1) + widths.reduce(0, +),
            height: height + pad * 2
        )

        let output = NSImage(size: total)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = scale > 3 ? .none : .high
        background.setFill()
        NSRect(origin: .zero, size: total).fill()

        var x = pad
        for (index, image) in rendered.enumerated() {
            image.draw(in: NSRect(x: x, y: pad, width: widths[index], height: height))
            x += widths[index] + pad
        }
        output.unlockFocus()
        return output
    }

    /// The colour ladder, in both shapes, across the readings that step through
    /// it. What this is for is judging the *gaps* between the rungs: three warm
    /// colours have to stay tellable apart at 2.2pt of stroke on a wallpaper
    /// nobody chose for legibility.
    private func escalation(scale: CGFloat, background: NSColor) -> NSImage {
        let brightness = background.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0.5
        let appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)!
        let ladder = MenuBarEscalation.default

        var rendered: [NSImage] = []
        appearance.performAsCurrentDrawingAppearance {
            for style in MenuBarIconStyle.allCases {
                // Healthy, one rung down, both rungs down — the three states of
                // the default ladder, in order.
                for pair in [[90.0, 80.0], [90.0, 40.0], [40.0, 10.0]] {
                    rendered.append(MenuBarIconRenderer.image(
                        style: style,
                        meters: pair.map { .init(fraction: $0) },
                        isStale: false,
                        escalation: ladder
                    ))
                }
            }
        }

        let pad: CGFloat = 12 * scale
        let height = MenuBarIconRenderer.barsSize.height * scale
        let widths = rendered.map { $0.size.width * scale }
        let total = NSSize(
            width: pad * CGFloat(rendered.count + 1) + widths.reduce(0, +),
            height: height + pad * 2
        )

        let output = NSImage(size: total)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = scale > 3 ? .none : .high
        background.setFill()
        NSRect(origin: .zero, size: total).fill()

        var x = pad
        for (index, image) in rendered.enumerated() {
            image.draw(in: NSRect(x: x, y: pad, width: widths[index], height: height))
            x += widths[index] + pad
        }
        output.unlockFocus()
        return output
    }

    @Test("Dump the escalation ladder in both shapes")
    func dumpEscalation() throws {
        let dark = NSColor(calibratedWhite: 0.13, alpha: 1)
        let light = NSColor(calibratedWhite: 0.93, alpha: 1)

        try write(escalation(scale: 2, background: dark), to: "escalation-dark-2x.png")
        try write(escalation(scale: 8, background: dark), to: "escalation-dark-8x.png")
        try write(escalation(scale: 2, background: light), to: "escalation-light-2x.png")

        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenmax-icons/escalation-dark-2x.png"))
    }

    @Test("Dump ring layouts and states")
    func dumpRings() throws {
        let dark = NSColor(calibratedWhite: 0.13, alpha: 1)
        let light = NSColor(calibratedWhite: 0.93, alpha: 1)

        try write(rings(scale: 2, background: dark), to: "rings-dark-2x.png")
        try write(rings(scale: 8, background: dark), to: "rings-dark-8x.png")
        try write(rings(scale: 2, background: light), to: "rings-light-2x.png")
        try write(rings(scale: 8, background: light), to: "rings-light-8x.png")

        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenmax-icons/rings-dark-8x.png"))
    }

    @Test("Dump bar layouts and alert states")
    func dumpLayouts() throws {
        let dark = NSColor(calibratedWhite: 0.13, alpha: 1)
        let light = NSColor(calibratedWhite: 0.93, alpha: 1)

        try write(layouts(scale: 2, background: dark), to: "layouts-dark-2x.png")
        try write(layouts(scale: 8, background: dark), to: "layouts-dark-8x.png")
        try write(layouts(scale: 8, background: light), to: "layouts-light-8x.png")

        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenmax-icons/layouts-dark-8x.png"))
    }

    @Test("Dump unlit vs lit at realistic sizes")
    func dumpComparisons() throws {
        // 2x = how it appears on a Retina menubar. 8x = detail inspection.
        let dark = NSColor(calibratedWhite: 0.13, alpha: 1)
        let light = NSColor(calibratedWhite: 0.93, alpha: 1)

        try write(comparison(scale: 2, background: dark, label: "dark"), to: "compare-dark-2x.png")
        try write(comparison(scale: 8, background: dark, label: "dark"), to: "compare-dark-8x.png")
        try write(comparison(scale: 2, background: light, label: "light"), to: "compare-light-2x.png")
        try write(comparison(scale: 8, background: light, label: "light"), to: "compare-light-8x.png")

        #expect(FileManager.default.fileExists(atPath: "/tmp/tokenmax-icons/compare-dark-2x.png"))
    }
}
