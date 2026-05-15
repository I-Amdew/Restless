import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let sourceURL = resourcesURL.appendingPathComponent("Restless.generated.png")
let iconsetURL = resourcesURL.appendingPathComponent("Restless.iconset", isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(
        domain: "RestlessIcon",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing Resources/Restless.generated.png"]
    )
}

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

func resizedImage(size: Int) -> NSImage {
    let targetSize = NSSize(width: size, height: size)
    let image = NSImage(size: targetSize)

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(
        in: NSRect(origin: .zero, size: targetSize),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1
    )

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "RestlessIcon", code: 2)
    }

    try pngData.write(to: url)
}

for iconSize in iconSizes {
    try writePNG(
        resizedImage(size: iconSize.pixels),
        to: iconsetURL.appendingPathComponent(iconSize.name)
    )
}
