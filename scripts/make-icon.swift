#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
//
// The icon is produced from code rather than checked in as a binary, so it can
// be reviewed in a diff and regenerated at any size. Run:
//
//   swift scripts/make-icon.swift
//
// Requires `iconutil`, which ships with macOS.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

/// Draw the icon at one size.
func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }

    // macOS icons sit on a rounded square with roughly a 22% corner radius,
    // inset slightly so the shape matches other icons in the Dock.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = CGPath(
        roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // Cool blue gradient: this is a cooling utility, and it reads clearly at
    // 16 pt where detail disappears.
    let colors = [
        CGColor(red: 0.30, green: 0.62, blue: 0.94, alpha: 1),
        CGColor(red: 0.10, green: 0.33, blue: 0.72, alpha: 1),
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    context.restoreGState()

    // Fan glyph, drawn rather than taken from SF Symbols so the icon does not
    // depend on a symbol staying available or being licensed for redistribution.
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let bladeLength = rect.width * 0.34
    let bladeWidth = rect.width * 0.26
    let hub = rect.width * 0.10

    // Three swept blades rather than four symmetric ones: an even count with
    // mirrored curves reads as a flower, and three thicker blades stay legible
    // at 16 pt where fine detail disappears entirely.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    for index in 0..<3 {
        context.saveGState()
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: CGFloat(index) * 2 * .pi / 3)

        // Asymmetric on purpose: the leading edge bulges and the trailing edge
        // cuts back, which is what makes it look like it turns.
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: -bladeWidth * 0.16, y: hub * 0.55))
        blade.addCurve(
            to: CGPoint(x: bladeWidth * 0.34, y: bladeLength),
            control1: CGPoint(x: -bladeWidth * 0.72, y: bladeLength * 0.46),
            control2: CGPoint(x: -bladeWidth * 0.24, y: bladeLength * 1.02)
        )
        blade.addCurve(
            to: CGPoint(x: bladeWidth * 0.20, y: hub * 0.5),
            control1: CGPoint(x: bladeWidth * 0.80, y: bladeLength * 0.90),
            control2: CGPoint(x: bladeWidth * 0.66, y: bladeLength * 0.30)
        )
        blade.closeSubpath()
        context.addPath(blade)
        context.fillPath()
        context.restoreGState()
    }

    // Hub drawn last so it sits cleanly over where the blades meet, with a hole
    // punched through so the shape reads as a fan rather than a pinwheel.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillEllipse(in: CGRect(
        x: centre.x - hub, y: centre.y - hub, width: hub * 2, height: hub * 2
    ))
    context.setBlendMode(.destinationOut)
    let hole = hub * 0.40
    context.fillEllipse(in: CGRect(
        x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2
    ))
    context.setBlendMode(.normal)

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    renderIcon(size: CGFloat(pixels)).draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels)
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

// The set of sizes iconutil expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try writePNG(renderIcon(size: CGFloat(variant.pixels)), pixels: variant.pixels, to: url)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
