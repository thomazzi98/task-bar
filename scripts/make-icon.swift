#!/usr/bin/env swift
//
// Draws the TaskBar app icon and writes it as an .icns file.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns
//
// The icon is generated rather than hand-drawn so it can be tweaked in code and rebuilt.

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

/// Renders the icon at `pixels` × `pixels`.
func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    // macOS icons leave a margin around the rounded square.
    let inset = size * 0.10
    let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = tile.width * 0.225
    let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.35, green: 0.47, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.95, alpha: 1)
    ])
    gradient?.draw(in: shape, angle: -60)

    // A faint highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Three checklist rows: a check mark, then two open circles, each with a line of "text".
    let rowHeight = tile.height * 0.19
    let left = tile.minX + tile.width * 0.22
    let top = tile.maxY - tile.height * 0.255
    let stroke = max(tile.width * 0.058, 1)
    NSColor.white.setStroke()
    NSColor.white.setFill()

    for row in 0..<3 {
        let centerY = top - CGFloat(row) * (rowHeight + tile.height * 0.055)
        let markSize = rowHeight * 0.78
        let mark = NSRect(x: left, y: centerY - markSize / 2, width: markSize, height: markSize)

        if row == 0 {
            let check = NSBezierPath()
            check.lineWidth = stroke
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: mark.minX + markSize * 0.08, y: mark.midY + markSize * 0.02))
            check.line(to: NSPoint(x: mark.minX + markSize * 0.40, y: mark.minY + markSize * 0.16))
            check.line(to: NSPoint(x: mark.maxX - markSize * 0.02, y: mark.maxY - markSize * 0.10))
            check.stroke()
        } else {
            let circle = NSBezierPath(ovalIn: mark.insetBy(dx: stroke * 0.5 + markSize * 0.06, dy: stroke * 0.5 + markSize * 0.06))
            circle.lineWidth = stroke * 0.78
            NSColor.white.withAlphaComponent(0.92).setStroke()
            circle.stroke()
        }

        let lineStart = mark.maxX + tile.width * 0.075
        let lineWidth = (tile.maxX - tile.width * 0.2 - lineStart) * (row == 2 ? 0.66 : 1)
        let line = NSRect(x: lineStart, y: centerY - stroke / 2, width: lineWidth, height: stroke)
        NSColor.white.withAlphaComponent(row == 0 ? 1 : 0.86).setFill()
        NSBezierPath(roundedRect: line, xRadius: stroke / 2, yRadius: stroke / 2).fill()
    }

    return bitmap.representation(using: .png, properties: [:])
}

// An .icns is built from an "iconset" folder holding each size at 1x and 2x.
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("TaskBar-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        guard let png = renderIcon(pixels: points * scale) else {
            FileHandle.standardError.write(Data("could not render \(points)pt @\(scale)x\n".utf8))
            exit(1)
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
