#!/usr/bin/env swift
// Builds Resources/AppIcon.icns from Resources/AppIcon.png.
//
//   swift scripts/make-icon.swift [source.png]
//
// Uses CoreGraphics rather than AppKit: `NSImage.lockFocus` needs a window
// server and fails on a CI runner, which is why regenerating the icon used to be
// opt-in. A bitmap context has no such dependency, so this runs anywhere.
//
// Requires `iconutil`, which ships with macOS.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let arguments = CommandLine.arguments
let source = URL(
    fileURLWithPath: arguments.count > 1 ? arguments[1] : "Resources/AppIcon.png",
    relativeTo: root
)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

/// Fraction of the canvas the artwork occupies.
///
/// Apple's macOS icon grid puts the shape in 824 points of a 1024 canvas and
/// leaves the rest transparent, which is where the system draws the icon's
/// shadow and how every icon lines up at the same visual size. Artwork that
/// fills the canvas edge to edge looks oversized beside everything else in
/// Finder and the Dock — a mistake that is invisible until you see it in a
/// folder next to real apps.
///
/// Override with MFS_ICON_SCALE=1 to keep artwork that already has its own
/// margin baked in.
let artworkScale = ProcessInfo.processInfo.environment["MFS_ICON_SCALE"]
    .flatMap(Double.init) ?? (824.0 / 1024.0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

guard FileManager.default.fileExists(atPath: source.path) else {
    fail("""
        no source image at \(source.path)

        Save the icon artwork as a square PNG at that path (1024×1024 or larger),
        then run this again.
        """)
}

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else {
    fail("could not read \(source.lastPathComponent) as an image")
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("make-icon: warning: \(message)\n".utf8))
}

if artwork.width != artwork.height {
    warn("source is \(artwork.width)×\(artwork.height), not square; "
         + "it will be squashed to fit")
}
if artwork.width < 1024 {
    warn("source is only \(artwork.width)px wide; 1024 or more gives a sharper "
         + "icon on Retina displays")
}

/// Corner radius of the mask, as a fraction of the artwork's own width.
///
/// Artwork exported without an alpha channel has opaque black in the corners
/// rather than nothing, which reads as a black *square* against any light
/// background — Finder in light mode, most obviously. Keying on the colour is
/// not an option: this icon has thousands of pure-black pixels in the middle of
/// the design, and they would be punched out too. So the corners are cut
/// geometrically instead.
///
/// macOS rounds icons at 22.37% of the side, and artwork drawn to that template
/// matches. The default here is deliberately a little rounder: a circular arc
/// and the continuous curve macOS actually uses diverge slightly near the
/// straight edges, and erring outwards would leave a thin black sliver there.
/// Erring inwards only trims a few pixels of flat background nobody can see.
///
/// Set MFS_ICON_CORNER=0 for artwork that is not a rounded square.
let cornerFraction = ProcessInfo.processInfo.environment["MFS_ICON_CORNER"]
    .flatMap(Double.init) ?? 0.24

/// Render the artwork centred on a transparent square canvas of `size` points.
func render(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    // Transparent, not filled: the margin has to stay clear for the system's
    // own shadow, and a white one would show as a box in dark mode.
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let inner = (Double(size) * artworkScale).rounded()
    let offset = ((Double(size) - inner) / 2).rounded()
    let frame = CGRect(x: offset, y: offset, width: inner, height: inner)

    if cornerFraction > 0 {
        let radius = inner * cornerFraction
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        context.clip()
    }
    context.draw(artwork, in: frame)

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// The set iconutil expects. Each entry is the nominal size and its @1x/@2x name.
let variants: [(size: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

try? FileManager.default.removeItem(at: iconset)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create \(iconset.path): \(error.localizedDescription)")
}

for variant in variants {
    guard let image = render(size: variant.size) else {
        fail("could not render \(variant.name)")
    }
    guard write(image, to: iconset.appendingPathComponent(variant.name)) else {
        fail("could not write \(variant.name)")
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
do {
    try iconutil.run()
} catch {
    fail("could not run iconutil: \(error.localizedDescription)")
}
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fail("iconutil failed with status \(iconutil.terminationStatus)")
}

let scalePercent = Int((artworkScale * 100).rounded())
print("wrote \(output.path) from \(source.lastPathComponent) at \(scalePercent)% of canvas")

// Also emit the copy the README shows, so the icon in the repository and the
// icon in the app cannot drift apart. Full bleed here: the transparent margin
// exists for the Dock's shadow, and standing alone on a page it just reads as
// a smaller image surrounded by nothing.
let readmeIcon = root.appendingPathComponent("docs/icon.png")
if let full = { () -> CGImage? in
    guard let context = CGContext(
        data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    let box = CGRect(x: 0, y: 0, width: 512, height: 512)
    context.clear(box)
    if cornerFraction > 0 {
        let radius = 512 * cornerFraction
        context.addPath(CGPath(
            roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        context.clip()
    }
    context.draw(artwork, in: box)
    return context.makeImage()
}() {
    try? FileManager.default.createDirectory(
        at: readmeIcon.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if write(full, to: readmeIcon) {
        print("wrote \(readmeIcon.path) for the README")
    } else {
        warn("could not write \(readmeIcon.path)")
    }
}
