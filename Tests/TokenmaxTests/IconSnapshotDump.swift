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
            unlit = MenuBarIconRenderer.image(session: 40, weekly: 70, isStale: false, isReady: false)
            lit = MenuBarIconRenderer.image(session: 40, weekly: 70, isStale: false, isReady: true)
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
