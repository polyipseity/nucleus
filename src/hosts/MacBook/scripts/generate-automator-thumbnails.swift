// generate-automator-thumbnails.swift — Generate QuickLook/Thumbnail.png for
// Automator workflow bundles from SF Symbol names.
//
// Usage: swift generate-automator-thumbnails.swift <symbol-name> <output-path>
//
// Renders a 256×256 PNG of the given SF Symbol at 120pt medium weight.
// Skips generation if the output file already exists (idempotent).
//
// WHY: Automator workflow bundles use QuickLook/Thumbnail.png for the Get Info
// window icon. Without it, macOS shows a generic workflow icon instead of the
// SF Symbol render. This script is run once per workflow to populate the PNG,
// which is then committed as a static asset.
//
// Requirements: macOS 11+ (SF Symbols), Swift with AppKit.

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: \(CommandLine.arguments[0]) <symbol-name> <output-path>\n", stderr)
    exit(1)
}

let symbolName = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

// Skip if output already exists (idempotent re-runs).
if FileManager.default.fileExists(atPath: outputPath) {
    print("Skipping \(outputPath) — already exists")
    exit(0)
}

guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    fputs("Error: SF Symbol '\(symbolName)' not found\n", stderr)
    exit(1)
}

let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .medium)
let configured = image.withSymbolConfiguration(config)!

let size = NSSize(width: 256, height: 256)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
configured.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Error: failed to create PNG data\n", stderr)
    exit(1)
}

// Create parent directory if needed.
let dir = (outputPath as NSString).deletingLastPathComponent
if !FileManager.default.fileExists(atPath: dir) {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Generated \(outputPath)")
