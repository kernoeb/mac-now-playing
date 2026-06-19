// Renders the app icon master PNG (1024x1024): a white music note on a rounded
// gradient square, INSET with macOS-style padding + a soft drop shadow so it
// matches the size of stock icons in Launchpad/Finder (a full-bleed square reads
// oversized next to them). Run: swift scripts/make-icon.swift <out.png>
// (then iconutil → AppIcon.icns).
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-master.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// The icon body is an inset rounded square: the macOS app-icon grid leaves ~10%
// padding around the artwork, so we don't fill the whole tile.
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let radius = body.width * 0.2256   // continuous-corner ratio of Apple's template

// Soft drop shadow: fill the body shape opaque once with a shadow set, then paint
// the real gradient on top of the same shape, leaving just the shadow halo behind.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
NSColor.black.setFill()
NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
ctx.restoreGState()

// Gradient fill, clipped to the body.
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
let grad = NSGradient(starting: NSColor(srgbRed: 0.40, green: 0.18, blue: 0.86, alpha: 1),
                      ending:   NSColor(srgbRed: 0.96, green: 0.33, blue: 0.56, alpha: 1))!
grad.draw(in: body, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// White music note (SF Symbol), centered in the body.
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    let white = NSImage(size: s)
    white.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)   // recolor glyph white
    white.unlockFocus()
    white.draw(at: NSPoint(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2),
               from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
