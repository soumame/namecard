#!/usr/bin/env swift
// Run from any directory: swift client/ios/tools/make_icon.swift
// Draws the app's code-native vector motif directly into the 1024px opaque catalog image.
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = root.appendingPathComponent("Namecard/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let size = 1024
guard let graphics = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                               bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Cannot create RGB icon bitmap") }
let context = NSGraphicsContext(cgContext: graphics, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let green = NSColor(srgbRed: 0.12, green: 0.38, blue: 0.30, alpha: 1)
let pale = NSColor(srgbRed: 0.94, green: 0.97, blue: 0.94, alpha: 1)
green.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.44, blue: 0.35, alpha: 1), ending: green)!
    .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -65)

// A physical landscape card and inset e-paper display, without brand marks or lettering.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.17)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -20)
shadow.set()
pale.setFill()
NSBezierPath(roundedRect: NSRect(x: 132, y: 280, width: 760, height: 464), xRadius: 66, yRadius: 66).fill()
NSShadow().set()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 166, y: 314, width: 692, height: 396), xRadius: 35, yRadius: 35).fill()

// A compact pixel portrait built from discrete 20px cells.
let pixels = [
    "00111100",
    "01111110",
    "01111110",
    "00111100",
    "00011000",
    "01111110",
    "11111111",
    "11111111"
]
green.setFill()
for (row, values) in pixels.enumerated() {
    for (column, value) in values.enumerated() where value == "1" {
        NSRect(x: 226 + column * 24, y: 390 + (7 - row) * 24, width: 21, height: 21).fill()
    }
}

for rectangle in [NSRect(x: 486, y: 545, width: 256, height: 28),
                  NSRect(x: 486, y: 481, width: 194, height: 20),
                  NSRect(x: 486, y: 429, width: 238, height: 20)] {
    NSBezierPath(roundedRect: rectangle, xRadius: 6, yRadius: 6).fill()
}

// Three near-field arcs sit above the card, with consistent stroked geometry.
pale.setStroke()
for radius in [CGFloat(31), 61, 91] {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: 758, y: 769), radius: radius, startAngle: 30, endAngle: 150)
    arc.lineWidth = 12
    arc.lineCapStyle = .round
    arc.stroke()
}
NSGraphicsContext.restoreGraphicsState()

guard let image = graphics.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("Cannot encode app icon") }
try png.write(to: destination.appendingPathComponent("AppIcon.png"), options: .atomic)
let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try Data(contents.utf8).write(to: destination.appendingPathComponent("Contents.json"), options: .atomic)
print("Generated \(destination.path)/AppIcon.png (1024×1024, RGB, opaque)")
