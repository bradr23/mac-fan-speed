#!/usr/bin/env swift
// Builds docs/social-preview.png — the card GitHub shows when the repository is
// linked on Slack, Discord, X and the like. Upload it under
// Settings › General › Social preview.
//
//   swift scripts/make-social-preview.swift
//
// GitHub wants 1280×640. Everything important is kept well inside the edges,
// because some clients crop the card to a squarer aspect ratio, and it has to
// stay legible at the couple-of-hundred pixels wide a chat client renders it at.
//
// CoreText and CoreGraphics only, no AppKit: same reason as make-icon.swift,
// this needs to run without a window server.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconURL = root.appendingPathComponent("docs/icon.png")
let output = root.appendingPathComponent("docs/social-preview.png")

let width = 1280.0
let height = 640.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-social-preview: \(message)\n".utf8))
    exit(1)
}

guard let iconSource = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(iconSource, 0, nil)
else {
    fail("""
        no icon at \(iconURL.path)
        Run `swift scripts/make-icon.swift` first — it produces that file.
        """)
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Pulled from the artwork so the card and the icon read as one thing.
let ink = rgb(11, 14, 20)
let inkTop = rgb(19, 24, 34)
let titleColour = rgb(244, 246, 250)
let bodyColour = rgb(150, 161, 178)
let metaColour = rgb(105, 116, 133)
let orange = rgb(255, 122, 24)
let blue = rgb(38, 144, 255)

guard let context = CGContext(
    data: nil,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("could not create the drawing context") }

context.interpolationQuality = .high

// MARK: Background

let space = CGColorSpaceCreateDeviceRGB()
if let gradient = CGGradient(
    colorsSpace: space, colors: [inkTop, ink] as CFArray, locations: [0, 1]
) {
    // Both extend options matter: the axis is diagonal, so without them
    // everything past either end is left unpainted — which shows up as a hard
    // black wedge across the corner.
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: width * 0.6, y: 0),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

/// Soft colour bloom, echoing the warm/cool arcs in the icon without competing
/// with it. Drawn before the icon so nothing sits on top of the artwork.
func glow(at point: CGPoint, radius: Double, colour: CGColor) {
    guard let components = colour.components, components.count >= 3 else { return }
    let bright = CGColor(
        red: components[0], green: components[1], blue: components[2], alpha: 0.30
    )
    let clear = CGColor(
        red: components[0], green: components[1], blue: components[2], alpha: 0
    )
    guard let gradient = CGGradient(
        colorsSpace: space, colors: [bright, clear] as CFArray, locations: [0, 1]
    ) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: point, startRadius: 0,
        endCenter: point, endRadius: radius,
        options: .drawsAfterEndLocation
    )
}

// Warm high on the left, cool low on the right — the same arrangement as the
// arcs in the icon. Kept off the text so nothing loses contrast behind it.
glow(at: CGPoint(x: 170, y: height - 140), radius: 430, colour: orange)
glow(at: CGPoint(x: width - 250, y: 90), radius: 430, colour: blue)

// MARK: Icon

let iconSize = 300.0
let iconX = 118.0
let iconY = (height - iconSize) / 2
context.draw(icon, in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize))

// MARK: Text

func font(_ size: Double, bold: Bool) -> CTFont {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    guard bold else { return base }
    return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
}

@discardableResult
func draw(_ text: String, _ ctFont: CTFont, _ colour: CGColor, x: Double, y: Double) -> Double {
    let attributes = [
        kCTFontAttributeName: ctFont,
        kCTForegroundColorAttributeName: colour,
    ] as CFDictionary
    guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)
    else { return 0 }
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
    return CTLineGetTypographicBounds(line, nil, nil, nil)
}

let textX = 500.0

draw("Mac Fan Speed", font(78, bold: true), titleColour, x: textX, y: 386)
draw("CPU temperature and fan control,", font(34, bold: false), bodyColour, x: textX, y: 316)
draw("in your menu bar.", font(34, bold: false), bodyColour, x: textX, y: 268)

// A short rule in the artwork's two accent colours, tying the block together.
context.setLineWidth(4)
context.setLineCap(.round)
context.setStrokeColor(orange)
context.move(to: CGPoint(x: textX, y: 218))
context.addLine(to: CGPoint(x: textX + 54, y: 218))
context.strokePath()
context.setStrokeColor(blue)
context.move(to: CGPoint(x: textX + 66, y: 218))
context.addLine(to: CGPoint(x: textX + 120, y: 218))
context.strokePath()

draw(
    "Apple Silicon  ·  macOS 14+  ·  Open source",
    font(26, bold: false), metaColour, x: textX, y: 168
)

// MARK: Write

guard let image = context.makeImage() else { fail("could not render the card") }
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
)
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fail("could not create \(output.path)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(output.path)") }

print("wrote \(output.path) (\(Int(width))×\(Int(height)))")
