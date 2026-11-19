// Renders the Offrecord app icon and packs it into an .icns via iconutil.
// The mark is an "O": its left half is the recording light, its right half
// turns into lines of text — audio becoming notes.
// Usage: swift scripts/make-icon.swift <out.icns> [preview.png]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let preview = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "Offrecord.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let coral = NSColor(red: 1.0, green: 0.37, blue: 0.29, alpha: 1)
let coralDeep = NSColor(red: 0.93, green: 0.22, blue: 0.24, alpha: 1)
let paper = NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1)

/// Draws the mark into a square of side `side` whose origin is `origin`, in a 24-unit grid.
func drawMark(origin: CGPoint, side: CGFloat) {
    let u = side / 24
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * u, y: origin.y + (24 - y) * u) }

    // Left half: recording light.
    let half = NSBezierPath()
    half.move(to: p(12, 3))
    half.appendArc(withCenter: p(12, 12), radius: 9 * u, startAngle: 90, endAngle: 270, clockwise: false)
    half.close()
    NSGradient(colors: [coral, coralDeep])!.draw(in: half, angle: -90)

    // Right half: the same circle, cut into lines of text.
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath()
    clip.move(to: p(12, 3))
    clip.appendArc(withCenter: p(12, 12), radius: 9 * u, startAngle: 90, endAngle: -90, clockwise: true)
    clip.close()
    clip.addClip()
    paper.setFill()
    let height: CGFloat = 2.2
    for y: CGFloat in [4.1, 8.05, 12.0, 15.95, 19.9] {
        let rect = NSRect(x: origin.x + 13.6 * u, y: origin.y + (24 - y - height / 2) * u, width: 10 * u, height: height * u)
        NSBezierPath(roundedRect: rect, xRadius: height * u / 2, yRadius: height * u / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        // macOS icon grid: 824/1024 tile with ~185 radius.
        let inset = s * 0.0977
        let tileRect = rect.insetBy(dx: inset, dy: inset)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: tileRect.width * 0.225, yRadius: tileRect.width * 0.225)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        shadow.shadowBlurRadius = s * 0.025
        shadow.set()
        NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1), NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)])!
            .draw(in: tile, angle: -90)
        let side = tileRect.width * 0.74
        drawMark(origin: CGPoint(x: tileRect.midX - side / 2, y: tileRect.midY - side / 2), side: side)
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
if let preview { try render(1024).write(to: URL(filePath: preview)) }
let task = Process()
task.executableURL = URL(filePath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
