// Renders the LiveTranslate app icon as a 1024×1024 PNG: a gradient
// rounded-square (the standard macOS "squircle" corner radius) with an
// SF Symbol composited on top, tinted white.
//
// Usage:
//     swift tools/make-icon.swift OUTPUT.png
//
// Then `iconutil -c icns` packs the rest of the sizes into a .icns. See
// tools/make-icon.sh.
import AppKit

// Tweak here to redesign the icon.
let symbolName = "bubble.left.and.text.bubble.right.fill"
let topColor   = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.96, alpha: 1.0)
let botColor   = NSColor(srgbRed: 0.05, green: 0.28, blue: 0.78, alpha: 1.0)
let symbolColor: NSColor = .white
let symbolScale: CGFloat = 0.58   // symbol size relative to icon size
let canvasSize: CGFloat = 1024

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift OUTPUT.png\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])

// 1. Build the symbol image, then mask it to a solid color (NSImage doesn't
//    expose a "render with color X" API directly; this is the canonical trick).
let symbolBase = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: canvasSize * symbolScale, weight: .semibold))!

let tintedSymbol = NSImage(size: symbolBase.size, flipped: false) { rect in
    symbolColor.setFill()
    rect.fill()
    symbolBase.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
    return true
}

// 2. Compose the full icon onto an NSImage.
let icon = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
icon.lockFocus()
let cg = NSGraphicsContext.current!.cgContext

let canvas = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
let cornerRadius = canvasSize * 0.2237   // Apple's macOS app-icon squircle radius

cg.saveGState()
cg.addPath(CGPath(roundedRect: canvas, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
cg.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(
    colorsSpace: cs,
    colors: [topColor.cgColor, botColor.cgColor] as CFArray,
    locations: [0.0, 1.0]
)!
cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvasSize), end: .zero, options: [])
cg.restoreGState()

let symRect = CGRect(
    x: (canvasSize - tintedSymbol.size.width) / 2,
    y: (canvasSize - tintedSymbol.size.height) / 2,
    width: tintedSymbol.size.width,
    height: tintedSymbol.size.height
)
tintedSymbol.draw(in: symRect)
icon.unlockFocus()

// 3. PNG encode.
guard let tiff = icon.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
    exit(1)
}
try png.write(to: outURL)
print("wrote \(outURL.path)")
