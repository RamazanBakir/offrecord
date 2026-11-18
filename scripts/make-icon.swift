// Renders the app icon from an SF Symbol and packs it into an .icns via iconutil.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "Offrecord.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.1
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.33, alpha: 1), NSColor(red: 0.85, green: 0.15, blue: 0.35, alpha: 1)])!
            .draw(in: tile, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let r = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: r)
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(filePath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
