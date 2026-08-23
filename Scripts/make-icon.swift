// Renders the Highball app icon (a highball glass, amber on charcoal) to a PNG.
// Usage: swift Scripts/make-icon.swift <output.png> [size]
import AppKit
import CoreGraphics

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let S = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1024 : 1024)

let image = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let u = S / 1024.0  // unit

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x * u, y: y * u, width: w * u, height: h * u),
               cornerWidth: r * u, cornerHeight: r * u, transform: nil)
    }
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func gradient(_ path: CGPath, _ top: UInt32, _ bottom: UInt32, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color(top, alpha), color(bottom, alpha)] as CFArray, locations: [0, 1])!
        let box = path.boundingBox
        ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.minY), options: [])
        ctx.restoreGState()
    }

    // macOS squircle-ish canvas with standard margin
    let plate = rr(100, 100, 824, 824, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 24 * u, color: color(0x000000, 0.35))
    gradient(plate, 0x2A2117, 0x16110A)
    ctx.restoreGState()

    // faint amber glow behind the glass
    let glow = CGPath(ellipseIn: CGRect(x: 292 * u, y: 210 * u, width: 440 * u, height: 300 * u), transform: nil)
    gradient(glow, 0xD79A45, 0x16110A, alpha: 0.18)

    // glass body (tall highball)
    let glass = rr(362, 240, 300, 560, 42)
    // liquid: lower two thirds
    ctx.saveGState()
    ctx.addPath(glass); ctx.clip()
    gradient(rr(362, 240, 300, 360, 42), 0xE3A94F, 0x9A5E17)
    // soda fizz head: thin lighter band at liquid surface
    ctx.setFillColor(color(0xF3CE8B, 0.85))
    ctx.fill(CGRect(x: 362 * u, y: 584 * u, width: 300 * u, height: 18 * u))
    ctx.restoreGState()

    // ice cubes
    for (x, y, r, a) in [(398.0, 470.0, -12.0, 0.85), (520.0, 420.0, 18.0, 0.75)] {
        ctx.saveGState()
        ctx.translateBy(x: (x + 55) * u, y: (y + 55) * u)
        ctx.rotate(by: r * .pi / 180)
        let cube = CGPath(roundedRect: CGRect(x: -55 * u, y: -55 * u, width: 110 * u, height: 110 * u),
                          cornerWidth: 22 * u, cornerHeight: 22 * u, transform: nil)
        ctx.addPath(cube)
        ctx.setFillColor(color(0xFFF6E6, a * 0.55))
        ctx.fillPath()
        ctx.addPath(cube)
        ctx.setStrokeColor(color(0xFFFFFF, 0.65))
        ctx.setLineWidth(6 * u)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // bubbles rising through the liquid
    for (x, y, r) in [(430.0, 300.0, 10.0), (560.0, 340.0, 13.0), (480.0, 380.0, 8.0), (610.0, 290.0, 9.0)] {
        ctx.setFillColor(color(0xFFF0D0, 0.7))
        ctx.fillEllipse(in: CGRect(x: (x - r) * u, y: (y - r) * u, width: 2 * r * u, height: 2 * r * u))
    }

    // glass outline + left highlight
    ctx.addPath(glass)
    ctx.setStrokeColor(color(0xF5EBDD, 0.9))
    ctx.setLineWidth(16 * u)
    ctx.strokePath()
    ctx.setStrokeColor(color(0xFFFFFF, 0.35))
    ctx.setLineWidth(10 * u)
    ctx.move(to: CGPoint(x: 396 * u, y: 730 * u))
    ctx.addLine(to: CGPoint(x: 396 * u, y: 330 * u))
    ctx.strokePath()

    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output) (\(Int(S))px)")
