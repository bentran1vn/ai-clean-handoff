// Render the real demo transcript as terminal frames (macOS + AppKit).
import AppKit
import Foundation

struct Frame: Decodable { let title: String; let lines: [String] }
let frames = try JSONDecoder().decode([Frame].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let width = 1200, height = 680
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1) }
for (index, frame) in frames.enumerated() {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    color(15,23,42).setFill(); NSRect(x:0,y:0,width:width,height:height).fill()
    color(30,41,59).setFill(); NSRect(x:0,y:604,width:width,height:76).fill()
    func text(_ value: String, x: Int, y: Int, size: CGFloat, tint: NSColor, bold: Bool = false) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        (value as NSString).draw(at: NSPoint(x:x,y:y), withAttributes:[.font:font,.foregroundColor:tint])
    }
    text("Copybara Release Sync",x:32,y:628,size:24,tint:.white,bold:true)
    text("LOCAL FIXTURE / CONDENSED DEMO",x:690,y:630,size:18,tint:color(94,234,212))
    text(frame.title,x:36,y:551,size:25,tint:color(94,234,212),bold:true)
    for (row, line) in frame.lines.prefix(12).enumerated() {
        var tint = color(226,232,240)
        if line.hasPrefix("+") || line.hasPrefix("PASS") { tint = color(134,239,172) }
        if line.hasPrefix("-") { tint = color(252,165,165) }
        if line.hasPrefix("$") { tint = color(147,197,253) }
        text(String(line.prefix(94)),x:36,y:493-row*34,size:20,tint:tint)
    }
    text("Filter artifacts. Preserve client files. Review before publish.",x:36,y:28,size:18,tint:color(148,163,184))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using:.png,properties:[:])!
    try data.write(to:directory.appendingPathComponent(String(format:"%02d.png",index)))
}
