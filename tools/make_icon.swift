import AppKit

// Draws the Presenter Notes app icon and writes it as a 1024 x 1024 PNG.
// usage: swift tools/make_icon.swift <output.png> [letters|lines]
//
// The default picture is a very large "Aa" on a dark screen, for large-print text, with a
// yellow line under it. It is kept this plain so it still reads at the smallest sizes.
// "lines" draws the alternative: three thick lines of text with the top one in yellow.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let output = arguments.first else { print("usage: make_icon.swift <output.png> [letters|lines]"); exit(1) }
let style = arguments.count > 1 ? arguments[1] : "letters"

let size: CGFloat = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.current = context

// The standard Mac icon shape: a rounded square inset from the canvas, with a soft shadow.
let shape = NSRect(x: 100, y: 100, width: 824, height: 824)
let outline = NSBezierPath(roundedRect: shape, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()

// Deep blue at the top fading to near black, like a dimmed room with a lit screen.
NSGraphicsContext.saveGraphicsState()
outline.addClip()
NSGradient(colors: [NSColor(red: 0.20, green: 0.27, blue: 0.68, alpha: 1),
                    NSColor(red: 0.07, green: 0.09, blue: 0.26, alpha: 1),
                    NSColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1)],
           atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?.draw(in: shape, angle: -90)
// A faint sheen across the top edge.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: shape.minX, y: shape.maxY - 260, width: shape.width, height: 260), angle: -90)
NSGraphicsContext.restoreGraphicsState()

let yellow = NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let white = NSColor(white: 1, alpha: 0.96)

func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, colour: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    glow.shadowBlurRadius = 18
    glow.shadowOffset = NSSize(width: 0, height: -8)
    glow.set()
    colour.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
}

if style == "letters" {
    // A very large "Aa" with a yellow line under it.
    let base = NSFont.systemFont(ofSize: 440, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 440) } ?? base
    let text = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: white])
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: 512 - textSize.height / 2 + 40))
    bar(x: 512 - 250, y: 232, width: 500, height: 62, colour: yellow)
} else {
    let height: CGFloat = 108, gap: CGFloat = 64, left: CGFloat = 232
    let top = 512 + (3 * height + 2 * gap) / 2
    bar(x: left, y: top - height, width: 560, height: height, colour: yellow)
    bar(x: left, y: top - 2 * height - gap, width: 560, height: height, colour: white)
    bar(x: left, y: top - 3 * height - 2 * gap, width: 350, height: height, colour: white)
}

context.flushGraphics()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
