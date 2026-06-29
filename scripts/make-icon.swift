// Generates StockBar's app icon: a dark squircle with a neon up-trend line +
// translucent area fill, matching the app's vibrant-dark aesthetic.
// Output: a 1024×1024 PNG at the path given as argv[1] (default /tmp/icon_1024.png).
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"
let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext

let full = NSRect(x: 0, y: 0, width: size, height: size)

// --- Squircle background with vertical gradient.
let corner = size * 0.2237
let bg = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)
bg.addClip()
let top = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1)
let bottom = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: full, angle: -90)

// --- Inner plot area.
let pad = size * 0.22
let w = size - pad * 2
let h = size - pad * 2
let pts: [(CGFloat, CGFloat)] = [
    (0.00, 0.28), (0.14, 0.40), (0.28, 0.30), (0.42, 0.52),
    (0.56, 0.44), (0.70, 0.66), (0.84, 0.74), (1.00, 0.90),
]
func P(_ p: (CGFloat, CGFloat)) -> NSPoint {
    NSPoint(x: pad + p.0 * w, y: pad + p.1 * h)
}

// --- Translucent area fill under the line (red, fading down).
let area = NSBezierPath()
area.move(to: NSPoint(x: P(pts[0]).x, y: pad))
for p in pts { area.line(to: P(p)) }
area.line(to: NSPoint(x: P(pts.last!).x, y: pad))
area.close()
NSGraphicsContext.saveGraphicsState()
area.addClip()
let fillTop = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.22, alpha: 0.55)
let fillBot = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.22, alpha: 0.0)
NSGradient(starting: fillTop, ending: fillBot)!.draw(in: full, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// --- The up-trend line itself, neon red with a soft glow.
let line = NSBezierPath()
line.move(to: P(pts[0]))
for p in pts.dropFirst() { line.line(to: P(p)) }
line.lineWidth = size * 0.045
line.lineCapStyle = .round
line.lineJoinStyle = .round
let neon = NSColor(srgbRed: 1.0, green: 0.30, blue: 0.24, alpha: 1.0)
cg.setShadow(offset: .zero, blur: size * 0.04,
             color: neon.withAlphaComponent(0.9).cgColor)
neon.setStroke()
line.stroke()
// Second pass without shadow for a crisp core.
cg.setShadow(offset: .zero, blur: 0, color: nil)
line.stroke()

// --- A bright node at the latest (highest) point.
let last = P(pts.last!)
let dotR = size * 0.035
let dot = NSBezierPath(ovalIn: NSRect(x: last.x - dotR, y: last.y - dotR, width: dotR * 2, height: dotR * 2))
NSColor.white.setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
