import AppKit
import Foundation

// Deterministic raster export of the supplied vector artwork using macOS.
// No image generation, external fonts, browser runtime or display capture.
guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]), (16...2048).contains(size),
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Usage: render.swift input.svg output.png size\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let rectangle = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
rectangle.fill(using: .copy)
image.draw(in: rectangle, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
