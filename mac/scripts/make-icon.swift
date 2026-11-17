// Draws the Paola Screen Studio logo and writes Resources/AppIcon.icns + Resources/Logo.png.
// Run: swift scripts/make-icon.swift   (from the mac/ folder)
import AppKit

func drawLogo(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let s = size / 1024
        // macOS icon grid: 824 pt rounded square centered in 1024.
        let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

        // Soft drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Background gradient: hot pink -> violet -> deep indigo.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = [
            CGColor(srgbRed: 1.00, green: 0.36, blue: 0.62, alpha: 1),
            CGColor(srgbRed: 0.62, green: 0.27, blue: 0.95, alpha: 1),
            CGColor(srgbRed: 0.20, green: 0.14, blue: 0.55, alpha: 1),
        ] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        // Top gloss.
        let gloss = CGGradient(colorsSpace: space, colors: [
            CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
        ctx.restoreGState()

        // Screen: white rounded frame.
        let screen = CGRect(x: 232 * s, y: 330 * s, width: 560 * s, height: 400 * s)
        let screenPath = CGPath(roundedRect: screen, cornerWidth: 56 * s, cornerHeight: 56 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(screenPath)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(34 * s)
        ctx.strokePath()
        ctx.restoreGState()

        // Stand.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 472 * s, y: 250 * s, width: 80 * s, height: 70 * s), cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 382 * s, y: 222 * s, width: 260 * s, height: 40 * s), cornerWidth: 20 * s, cornerHeight: 20 * s, transform: nil))
        ctx.fillPath()

        // Record dot with halo, centered in the screen.
        let center = CGPoint(x: screen.midX, y: screen.midY)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
        ctx.fillEllipse(in: CGRect(x: center.x - 118 * s, y: center.y - 118 * s, width: 236 * s, height: 236 * s))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 88 * s, y: center.y - 88 * s, width: 176 * s, height: 176 * s))
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.27, blue: 0.42, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - 64 * s, y: center.y - 64 * s, width: 128 * s, height: 128 * s))

        // Sparkle (top-right of the screen).
        func sparkle(at p: CGPoint, r: CGFloat) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p.x, y: p.y + r))
            path.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + r * 0.15, y: p.y + r * 0.15))
            path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x + r * 0.15, y: p.y - r * 0.15))
            path.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - r * 0.15, y: p.y - r * 0.15))
            path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x - r * 0.15, y: p.y + r * 0.15))
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
        }
        sparkle(at: CGPoint(x: 812 * s, y: 818 * s), r: 56 * s)
        sparkle(at: CGPoint(x: 722 * s, y: 866 * s), r: 24 * s)
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let logo = drawLogo(size: 1024)
for base in [16, 32, 128, 256, 512] {
    try png(logo, pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(logo, pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(logo, pixels: 1024).write(to: URL(fileURLWithPath: "Resources/Logo.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Listo: Resources/AppIcon.icns y Resources/Logo.png" : "iconutil falló")
