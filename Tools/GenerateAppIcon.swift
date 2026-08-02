#!/usr/bin/env swift

// Renders Tokenmax.app's icon into the asset catalog.
//
//   swift Tools/GenerateAppIcon.swift
//
// The icon restates the menubar glyph — two horizontal quota meters — at app
// scale: a green session bar over a paler weekly bar on a dark rounded square.
// Keeping it generated rather than hand-drawn means the design is a diff, not
// an opaque binary blob, and the whole set regenerates from one edit.

import AppKit
import Foundation

// MARK: - Design, expressed on a 1024pt canvas

private let canvas: CGFloat = 1024

/// Apple's macOS icon grid: the rounded square occupies 824pt of the 1024pt
/// canvas, leaving room for the shadow. Corner radius is ~22.5% of its side.
private let plateInset: CGFloat = 100
private let plateSide: CGFloat = 824
private let plateRadius: CGFloat = 185

private let barWidth: CGFloat = 560
private let barHeight: CGFloat = 112
private let barGap: CGFloat = 60

/// Session sits fuller than weekly — the icon should read as a live meter
/// rather than a symmetric logo.
private let sessionFill: CGFloat = 0.72
private let weeklyFill: CGFloat = 0.46

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

private let plateTop = rgb(38, 45, 60)
private let plateBottom = rgb(13, 16, 23)

private let sessionTop = rgb(74, 231, 122)
private let sessionBottom = rgb(22, 178, 68)

private let weeklyTop = rgb(226, 234, 245)
private let weeklyBottom = rgb(166, 179, 199)

private func drawDesign() {
    let plate = NSRect(x: plateInset, y: plateInset, width: plateSide, height: plateSide)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: plateRadius, yRadius: plateRadius)

    // Drop shadow, drawn with the plate so it does not fall behind the bars.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 22
    shadow.set()
    NSColor.black.setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: plateBottom, ending: plateTop)?.draw(in: platePath, angle: 90)

    // Soft gloss across the top third, so the plate is not a flat rectangle.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    let gloss = NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2)
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0),
        ending: NSColor.white.withAlphaComponent(0.10)
    )?.draw(in: gloss, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline rim: lifts the plate off a dark desktop.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    platePath.lineWidth = 3
    platePath.stroke()

    let stackHeight = barHeight * 2 + barGap
    let originY = (canvas - stackHeight) / 2
    let originX = (canvas - barWidth) / 2

    drawMeter(
        rect: NSRect(x: originX, y: originY + barHeight + barGap, width: barWidth, height: barHeight),
        fill: sessionFill,
        top: sessionTop,
        bottom: sessionBottom
    )
    drawMeter(
        rect: NSRect(x: originX, y: originY, width: barWidth, height: barHeight),
        fill: weeklyFill,
        top: weeklyTop,
        bottom: weeklyBottom
    )
}

private func drawMeter(rect: NSRect, fill: CGFloat, top: NSColor, bottom: NSColor) {
    let radius = rect.height / 2

    let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.white.withAlphaComponent(0.13).setFill()
    track.fill()

    let filled = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * fill), height: rect.height)
    let filledPath = NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius)
    NSGradient(starting: bottom, ending: top)?.draw(in: filledPath, angle: 90)
}

// MARK: - Rasterization

private func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // Draw once in 1024pt terms and scale down, so every size is the same design.
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / canvas)
    transform.concat()

    drawDesign()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Asset catalog

private struct Entry {
    let size: Int
    let scale: Int

    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

private let entries = [16, 32, 128, 256, 512].flatMap { size in
    [Entry(size: size, scale: 1), Entry(size: size, scale: 2)]
}

private let iconSetURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/Tokenmax/Resources/Assets.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: iconSetURL.path) else {
    FileHandle.standardError.write(Data("run this from the repository root\n".utf8))
    exit(1)
}

for entry in entries {
    guard let data = render(pixels: entry.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(entry.filename)\n".utf8))
        exit(1)
    }
    try data.write(to: iconSetURL.appendingPathComponent(entry.filename))
    print("wrote \(entry.filename) (\(entry.pixels)px)")
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""

try contents.write(to: iconSetURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
