// Renders the app icon (a white ring gauge on a blue tile) into an .appiconset.
// Usage: swift scripts/make_icon.swift [App/Assets.xcassets/AppIcon.appiconset]
import AppKit

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset"
let out = URL(fileURLWithPath: path)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let s = CGFloat(px)
        let inset = s * 0.1
        let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let squircle = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

        // Drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Blue tile
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        let colors = [NSColor(red: 0.43, green: 0.65, blue: 0.93, alpha: 1).cgColor,
                      NSColor(red: 0.11, green: 0.36, blue: 0.67, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

        // Ring gauge: a faint full track and a ~72% arc from 12 o'clock, clockwise.
        let center = CGPoint(x: tile.midX, y: tile.midY)
        let radius = tile.width * 0.27
        let line = tile.width * 0.1
        ctx.setLineWidth(line)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * 0.72, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(path)")
