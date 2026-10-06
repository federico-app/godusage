// Renders the DMG window background (assets/dmg/background.png and background@2x.png).
// Run after changing the layout: swift script/render_dmg_background.swift
// release.sh places the icons to match: window 660×400, app at (165, 210), Applications at (495, 210).
import AppKit

let size = NSSize(width: 660, height: 400)
let accent = NSColor(srgbRed: 0.77, green: 0.38, blue: 0.17, alpha: 1)   // #C4622C, the site accent
let ink = NSColor(srgbRed: 0.17, green: 0.15, blue: 0.13, alpha: 1)
let muted = NSColor(srgbRed: 0.48, green: 0.44, blue: 0.39, alpha: 1)

func render(scale: CGFloat, to path: String) throws {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw NSError(domain: "render", code: 1) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin, like Finder's icon positions.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)

    NSGradient(
        starting: NSColor(srgbRed: 0.973, green: 0.957, blue: 0.925, alpha: 1),
        ending: NSColor(srgbRed: 0.925, green: 0.894, blue: 0.839, alpha: 1)
    )!.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    func centered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = string.size().width
        // Text draws upright in a flipped context only through a flipped graphics context.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        string.draw(at: NSPoint(x: (size.width - width) / 2, y: y))
        NSGraphicsContext.current = context
    }
    centered("Install GodUsage", font: .systemFont(ofSize: 22, weight: .bold), color: ink, y: 38)
    centered("Drag the app onto the Applications folder.", font: .systemFont(ofSize: 13), color: muted, y: 70)

    // A dashed arrow from the app to Applications, at icon-center height.
    let y: CGFloat = 210
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 262, y: y))
    line.line(to: NSPoint(x: 384, y: y))
    line.lineWidth = 4
    line.lineCapStyle = .round
    line.setLineDash([2, 10], count: 2, phase: 0)
    accent.setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 382, y: y - 11))
    head.line(to: NSPoint(x: 398, y: y))
    head.line(to: NSPoint(x: 382, y: y + 11))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "render", code: 2) }
    try png.write(to: URL(fileURLWithPath: path))
}

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/dmg").path
try render(scale: 1, to: "\(directory)/background.png")
try render(scale: 2, to: "\(directory)/background@2x.png")
print("wrote \(directory)/background.png and background@2x.png")
