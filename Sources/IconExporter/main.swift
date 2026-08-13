// Sources/IconExporter/main.swift
//
// Renders `RatchetIcon` to the PNG assets the app needs on disk: a macOS `.iconset` (which
// `iconutil` turns into `Resources/AppIcon.icns`, picked up by scripts/build-app.sh) and a
// standalone FreeAgent listing icon. Run with:
//
//   swift run IconExporter
//   iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
//
// (iconutil is a separate step, not shelled out to here, so this target stays a plain renderer
// with no process-spawning side effects.)
import AppKit
import RatchetCore

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = root.appendingPathComponent(".build/AppIcon.iconset")
let designDir = root.appendingPathComponent("design/icons")

func writePNG(_ image: NSImage, size: CGFloat, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("Couldn't allocate a bitmap rep for \(url.lastPathComponent)")
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Couldn't encode PNG for \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("wrote \(url.path) (\(Int(size))x\(Int(size)))")
}

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Standard macOS iconset: base sizes and their @2x doubles. iconutil expects exactly this
// naming and pixel-size convention.
let iconsetSizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
]
for entry in iconsetSizes {
    let pixels = entry.points * entry.scale
    let image = RatchetIcon.appTile(size: pixels)
    writePNG(image, size: pixels, to: iconsetDir.appendingPathComponent("\(entry.name).png"))
}

// FreeAgent listing icon: the same green-tile treatment as the Dock icon, since it's
// self-contained (works on any host background) rather than a transparent mark that could
// vanish depending on where FreeAgent places it.
let freeAgentIcon = RatchetIcon.appTile(size: 512)
writePNG(freeAgentIcon, size: 512, to: designDir.appendingPathComponent("freeagent-icon.png"))

print("\nNext: iconutil -c icns \(iconsetDir.path) -o Resources/AppIcon.icns")
