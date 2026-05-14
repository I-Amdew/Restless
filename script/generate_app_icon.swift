import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("Restless.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func iconImage(size: Int) -> NSImage {
    let side = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    let image = NSImage(size: rect.size)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let backgroundRect = rect.insetBy(dx: side * 0.035, dy: side * 0.035)
    let backgroundPath = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: side * 0.22,
        yRadius: side * 0.22
    )
    backgroundPath.addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.00, green: 0.47, blue: 1.00, alpha: 1.0),
        NSColor(calibratedRed: 0.00, green: 0.22, blue: 0.72, alpha: 1.0),
        NSColor(calibratedRed: 0.01, green: 0.08, blue: 0.20, alpha: 1.0),
    ])?.draw(in: backgroundRect, angle: -38)

    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: side * 0.12, y: side * 0.58, width: side * 0.48, height: side * 0.36)).fill()

    NSColor.systemOrange.withAlphaComponent(0.95).setFill()
    NSBezierPath(ovalIn: NSRect(x: side * 0.70, y: side * 0.70, width: side * 0.12, height: side * 0.12)).fill()

    let screenRect = NSRect(x: side * 0.21, y: side * 0.35, width: side * 0.58, height: side * 0.36)
    let screenPath = NSBezierPath(
        roundedRect: screenRect,
        xRadius: side * 0.035,
        yRadius: side * 0.035
    )
    NSColor.white.setStroke()
    screenPath.lineWidth = max(2, side * 0.055)
    screenPath.stroke()

    let standPath = NSBezierPath()
    standPath.lineWidth = max(2, side * 0.055)
    standPath.lineCapStyle = .round
    standPath.move(to: NSPoint(x: side * 0.50, y: side * 0.34))
    standPath.line(to: NSPoint(x: side * 0.50, y: side * 0.23))
    standPath.move(to: NSPoint(x: side * 0.37, y: side * 0.22))
    standPath.line(to: NSPoint(x: side * 0.63, y: side * 0.22))
    standPath.stroke()

    NSColor.white.withAlphaComponent(0.28).setStroke()
    let insetPath = NSBezierPath(
        roundedRect: screenRect.insetBy(dx: side * 0.035, dy: side * 0.035),
        xRadius: side * 0.02,
        yRadius: side * 0.02
    )
    insetPath.lineWidth = max(1, side * 0.014)
    insetPath.stroke()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "RestlessIcon", code: 1)
    }

    try pngData.write(to: url)
}

for iconSize in iconSizes {
    try writePNG(
        iconImage(size: iconSize.pixels),
        to: iconsetURL.appendingPathComponent(iconSize.name)
    )
}
