// Sources/IconExporter/main.swift
//
// Renders `RatchetIcon` to the PNG assets the app needs on disk: a macOS `.iconset` (which
// `iconutil` turns into an `.icns`) and a standalone FreeAgent listing icon. Run with:
//
//   swift run IconExporter [output-dir]        # output-dir defaults to ./.build/icons
//   iconutil -c icns <output-dir>/AppIcon.iconset -o Resources/AppIcon.icns
//
// scripts/build-app.sh runs both steps itself, so a bundle's icon always matches current source;
// running by hand is for refreshing the committed Resources/AppIcon.icns and the FreeAgent icon.
//
// The output directory comes from the command line rather than being derived from `#filePath`,
// which is fixed at compile time: SwiftPM will happily reuse a cached binary after the checkout
// has moved, and that binary would then write into a path that no longer exists. Defaulting under
// .build also keeps a hand-run export from silently overwriting tracked files.
//
// (iconutil is a separate step, not shelled out to here, so this target stays a plain renderer
// with no process-spawning side effects.)
import AppKit
import RatchetCore

let outputRoot = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/icons",
    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
).standardizedFileURL
let iconsetDir = outputRoot.appendingPathComponent("AppIcon.iconset")

func writePNG(_ image: NSImage, size: CGFloat, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        fatalError("Couldn't allocate a bitmap rep for \(url.lastPathComponent)")
    }
    rep.size = NSSize(width: size, height: size)

    // A nil context here is not survivable: drawing would no-op, PNG encoding would still succeed
    // on the untouched buffer, and the tool would report having written a fully transparent icon.
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Couldn't make a drawing context for \(url.lastPathComponent)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Couldn't encode PNG for \(url.lastPathComponent)")
    }
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    } catch {
        fatalError("Couldn't write \(url.path): \(error.localizedDescription)")
    }
    print("wrote \(url.path) (\(Int(size))x\(Int(size)))")
}

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
// vanish depending on where FreeAgent places it. Copy it over design/icons/freeagent-icon.png
// by hand when it changes — that file is tracked, so this tool shouldn't rewrite it unasked.
let freeAgentIcon = RatchetIcon.appTile(size: 512)
writePNG(freeAgentIcon, size: 512, to: outputRoot.appendingPathComponent("freeagent-icon.png"))

print("\nNext: iconutil -c icns \(iconsetDir.path) -o Resources/AppIcon.icns")
