#!/usr/bin/env swift

import AppKit
import Foundation

let width: CGFloat = 1320
let height: CGFloat = 2868
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("AppStoreAssets/Screenshots/en-US/source-v2")
let output = root.appendingPathComponent("AppStoreAssets/Screenshots/en-US/final-v2")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let mint = NSColor(calibratedRed: 0.02, green: 0.84, blue: 0.76, alpha: 1)
let white = NSColor(calibratedWhite: 0.98, alpha: 1)
let secondary = NSColor(calibratedWhite: 0.72, alpha: 1)

func topRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: height - y - h, width: w, height: h)
}

func image(_ name: String) throws -> NSImage {
    let url = source.appendingPathComponent(name)
    guard let value = NSImage(contentsOf: url) else {
        throw NSError(domain: "HydroToneScreenshots", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not read \(url.path)"])
    }
    return value
}

func drawText(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
              font: NSFont, color: NSColor, lineHeight: CGFloat? = nil) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let attributed = NSAttributedString(string: value, attributes: attributes)
    let measured = attributed.boundingRect(with: NSSize(width: width, height: 600),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading])
    attributed.draw(in: topRect(x, y, width, ceil(measured.height)))
}

func drawBackground() {
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.01, green: 0.04, blue: 0.06, alpha: 1),
        NSColor(calibratedRed: 0.00, green: 0.01, blue: 0.02, alpha: 1)
    ])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    let glow = NSGradient(starting: mint.withAlphaComponent(0.20), ending: mint.withAlphaComponent(0))!
    glow.draw(in: topRect(760, -180, 760, 760), relativeCenterPosition: .zero)
}

func drawHeader(_ headline: String, _ detail: String, number: Int) {
    let pill = topRect(72, 76, 235, 54)
    mint.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 27, yRadius: 27).fill()
    drawText("HYDROTONE", x: 102, y: 88, width: 210,
             font: .systemFont(ofSize: 25, weight: .semibold), color: mint)
    drawText(headline, x: 72, y: 166, width: 1176,
             font: .systemFont(ofSize: 78, weight: .bold), color: white, lineHeight: 86)
    drawText(detail, x: 76, y: 360, width: 1160,
             font: .systemFont(ofSize: 34, weight: .regular), color: secondary, lineHeight: 43)
    drawText(String(format: "%02d", number), x: 1170, y: 90, width: 80,
             font: .monospacedDigitSystemFont(ofSize: 27, weight: .medium), color: secondary)
}

func drawRoundedImage(_ value: NSImage, in rect: NSRect, radius: CGFloat = 54) {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    value.draw(in: rect, from: NSRect(origin: .zero, size: value.size), operation: .sourceOver,
               fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(_ filename: String, draw: () throws -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width),
                                        pixelsHigh: Int(height), bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                        bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "HydroToneScreenshots", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create canvas"])
    }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawBackground()
    try draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.94]) else {
        throw NSError(domain: "HydroToneScreenshots", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Could not encode \(filename)"])
    }
    try jpeg.write(to: output.appendingPathComponent(filename), options: .atomic)
}

func drawScreenshotCard(_ name: String) throws {
    let shot = try image(name)
    drawRoundedImage(shot, in: topRect(122, 500, 1076, 2338), radius: 58)
}

try render("01-before-after.jpg") {
    drawHeader("See the difference.\nInstantly.",
               "A real HydroTone correction from the same frame.", number: 1)
    let before = try image("01-photo-before.png")
    let after = try image("01-photo-after.png")
    let card = topRect(70, 600, 1180, 1096)
    let left = NSRect(x: card.minX, y: card.minY, width: card.width / 2, height: card.height)
    let right = NSRect(x: card.midX, y: card.minY, width: card.width / 2, height: card.height)
    let crop = NSRect(x: 260, y: before.size.height - 620 - 743, width: 800, height: 743)

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: card, xRadius: 50, yRadius: 50).addClip()
    NSBezierPath(rect: left).addClip()
    before.draw(in: card, from: crop, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: card, xRadius: 50, yRadius: 50).addClip()
    NSBezierPath(rect: right).addClip()
    after.draw(in: card, from: crop, operation: .sourceOver, fraction: 1,
               respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.current?.restoreGraphicsState()

    mint.setFill()
    NSBezierPath(rect: NSRect(x: card.midX - 3, y: card.minY, width: 6, height: card.height)).fill()
    drawText("BEFORE", x: 112, y: 1600, width: 220,
             font: .systemFont(ofSize: 26, weight: .bold), color: white)
    drawText("AFTER", x: 1020, y: 1600, width: 220,
             font: .systemFont(ofSize: 26, weight: .bold), color: white)

    let benefits = [
        ("Depth-aware", "Colour recovery"),
        ("On-device", "Private processing"),
        ("One slider", "Your intensity")
    ]
    for (index, benefit) in benefits.enumerated() {
        let x = 70 + CGFloat(index) * 398
        let rect = topRect(x, 1800, 378, 268)
        NSColor.white.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38).fill()
        drawText(benefit.0, x: x + 34, y: 1850, width: 310,
                 font: .systemFont(ofSize: 35, weight: .semibold), color: white)
        drawText(benefit.1, x: x + 34, y: 1912, width: 310,
                 font: .systemFont(ofSize: 27, weight: .regular), color: secondary)
    }
    drawText("Bring back the dive—not an artificial look.", x: 74, y: 2190, width: 1160,
             font: .systemFont(ofSize: 46, weight: .semibold), color: white, lineHeight: 58)
    drawText("Choose Natural Dive, Tropical or Deep Dive, then compare with the original at any time.",
             x: 74, y: 2320, width: 1120, font: .systemFont(ofSize: 34, weight: .regular),
             color: secondary, lineHeight: 48)
}

try render("02-deep-dive.jpg") {
    drawHeader("Blue water.\nClearer depth.",
               "Deep Dive adds stronger colour separation and clarity.", number: 2)
    try drawScreenshotCard("01-photo-after.png")
}

try render("03-video.jpg") {
    drawHeader("Stable colour.\nFrame after frame.",
               "Restore underwater video without distracting colour flicker.", number: 3)
    try drawScreenshotCard("03-video-natural.png")
}

try render("04-export.jpg") {
    drawHeader("Keep the quality\nyou captured.",
               "Preserve frame rate, 4K and supported HDR with HydroTone Pro.", number: 4)
    try drawScreenshotCard("04-export-options.png")
}

try render("05-video-before-after.jpg") {
    drawHeader("Video, before\nand after.",
               "The same paused frame, corrected by HydroTone.", number: 5)
    let before = try image("06-video-before.jpg")
    let after = try image("06-video-after.jpg")
    let card = topRect(70, 600, 1180, 1096)
    let left = NSRect(x: card.minX, y: card.minY, width: card.width / 2, height: card.height)
    let right = NSRect(x: card.midX, y: card.minY, width: card.width / 2, height: card.height)
    let crop = NSRect(x: 380, y: 0, width: 1160, height: 1080)

    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: card, xRadius: 50, yRadius: 50).addClip()
    NSBezierPath(rect: left).addClip()
    before.draw(in: card, from: crop, operation: .sourceOver, fraction: 1,
                respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: card, xRadius: 50, yRadius: 50).addClip()
    NSBezierPath(rect: right).addClip()
    after.draw(in: card, from: crop, operation: .sourceOver, fraction: 1,
               respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.current?.restoreGraphicsState()

    mint.setFill()
    NSBezierPath(rect: NSRect(x: card.midX - 3, y: card.minY, width: 6, height: card.height)).fill()
    drawText("ORIGINAL", x: 112, y: 1600, width: 240,
             font: .systemFont(ofSize: 26, weight: .bold), color: white)
    drawText("DEEP DIVE", x: 976, y: 1600, width: 250,
             font: .systemFont(ofSize: 26, weight: .bold), color: white)

    let benefits = [
        ("Same frame", "Honest comparison"),
        ("Stable grade", "Across the clip"),
        ("Audio intact", "Timing preserved")
    ]
    for (index, benefit) in benefits.enumerated() {
        let x = 70 + CGFloat(index) * 398
        let rect = topRect(x, 1800, 378, 268)
        NSColor.white.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38).fill()
        drawText(benefit.0, x: x + 34, y: 1850, width: 310,
                 font: .systemFont(ofSize: 35, weight: .semibold), color: white)
        drawText(benefit.1, x: x + 34, y: 1912, width: 310,
                 font: .systemFont(ofSize: 27, weight: .regular), color: secondary)
    }
    drawText("Colour that holds together while the scene moves.", x: 74, y: 2190, width: 1160,
             font: .systemFont(ofSize: 46, weight: .semibold), color: white, lineHeight: 58)
    drawText("HydroTone analyses the clip and applies a temporally stable correction frame after frame.",
             x: 74, y: 2320, width: 1120, font: .systemFont(ofSize: 34, weight: .regular),
             color: secondary, lineHeight: 48)
}

print("Created 5 screenshots in \(output.path)")
