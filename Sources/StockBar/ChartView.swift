import AppKit
import StockCore

/// Renders today's minute-level price line.
/// Two modes:
///   .mini : compact sparkline (no axes, no labels) for inline rows.
///   .full : full chart with prev-close baseline, time gridlines (09:30/11:30/13:00/15:00),
///           and y-axis pct labels.
final class ChartView: NSView {
    enum Style {
        case mini
        case full
    }

    var style: Style = .mini { didSet { needsDisplay = true } }

    /// Today's minute points (sparse — may be only a few if market just opened).
    var points: [MinutePoint] = [] { didSet { needsDisplay = true } }

    /// Previous close, used to color the line and draw baseline (full mode).
    var prevClose: Double? { didSet { needsDisplay = true } }

    /// The most-recent live price for direction coloring. This is sourced from
    /// the realtime quote endpoint (refreshes every few seconds) and is usually
    /// fresher than the trailing edge of `points` (the minute series refreshes
    /// every ~30 s). When set, the line color is computed from
    /// `currentPrice` vs `prevClose` so the sparkline always agrees with the
    /// pct text on the row.
    var currentPrice: Double? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        // Background
        if style == .full {
            NSColor.textBackgroundColor.withAlphaComponent(0.04).setFill()
            bounds.fill()
        }

        guard !points.isEmpty else {
            if style == .full {
                drawNoDataPlaceholder(in: bounds)
            }
            return
        }

        // Determine y-range. Use prevClose as a strong anchor when available
        // so the baseline (0% line) is always visually meaningful.
        let prices = points.map(\.price)
        var lo = prices.min() ?? 0
        var hi = prices.max() ?? 1
        if let pc = prevClose {
            // Make baseline appear roughly centered: extend bounds to include prevClose
            // and then add a symmetric padding.
            lo = min(lo, pc)
            hi = max(hi, pc)
            let halfRange = max(abs(hi - pc), abs(pc - lo), 0.0001)
            lo = pc - halfRange
            hi = pc + halfRange
        }
        if hi - lo < 1e-8 {
            hi = lo + 1
        }

        // Determine x-range: full trading day = 240 minutes. The line then
        // occupies as much horizontal space as time has actually progressed —
        // narrow strip in early session, full width by close. Mini sparkline
        // and full chart share the same mapping so their shapes match.
        let xMax: Double = 240

        // Insets
        let insets: NSEdgeInsets
        switch style {
        case .mini: insets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 8)   // leave room for end-dot
        case .full: insets = NSEdgeInsets(top: 12, left: 40, bottom: 22, right: 12)
        }
        let plot = NSRect(
            x: bounds.minX + insets.left,
            y: bounds.minY + insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom
        )
        guard plot.width > 1, plot.height > 1 else { return }

        // Determine line color from the live quote price (preferred) or the
        // last minute point. The two can disagree by a few seconds because the
        // realtime quote refreshes faster than the minute series.
        let latest = currentPrice ?? prices.last ?? 0
        let isUp: Bool
        if let pc = prevClose {
            isUp = latest >= pc
        } else {
            isUp = latest >= (prices.first ?? latest)
        }
        // Custom high-vibrancy colors for dark mode glassmorphism
        let neonRed = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.22, alpha: 1.0) // #ff453a
        let neonGreen = NSColor(calibratedRed: 0.19, green: 0.84, blue: 0.29, alpha: 1.0) // #32d74b
        let lineColor: NSColor = isUp ? neonRed : neonGreen

        if style == .full {
            drawFullDecorations(plot: plot, lo: lo, hi: hi, prevClose: prevClose)
        }

        // Build the price path and area-fill path.
        let path = NSBezierPath()
        let area = NSBezierPath()
        var lastPoint: NSPoint = .zero
        for (idx, p) in points.enumerated() {
            let x = plot.minX + plot.width * CGFloat(Double(p.minutesFromOpen) / xMax)
            let yNorm = (p.price - lo) / (hi - lo)
            let y = plot.minY + plot.height * CGFloat(yNorm)
            let pt = NSPoint(x: x, y: y)
            if idx == 0 {
                path.move(to: pt)
                area.move(to: NSPoint(x: x, y: plot.minY))
                area.line(to: pt)
            } else {
                path.line(to: pt)
                area.line(to: pt)
            }
            lastPoint = pt
        }
        // Close the area down to baseline.
        area.line(to: NSPoint(x: lastPoint.x, y: plot.minY))
        area.close()

        // -- Gradient area fill (vertical, fades out toward baseline) --
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            let clip = area.cgPathCompat
            ctx.addPath(clip)
            ctx.clip()
            let topColor = lineColor.withAlphaComponent(style == .full ? 0.35 : 0.40)
            let bottomColor = lineColor.withAlphaComponent(0.02)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
                locations: [0.0, 1.0]
            ) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: plot.maxY),
                    end: CGPoint(x: 0, y: plot.minY),
                    options: []
                )
            }
            ctx.restoreGState()
        }

        // -- Glow under the line --
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // Drop shadow for the neon glow effect
            let blurRadius: CGFloat = (style == .mini ? 3 : 6)
            ctx.setShadow(offset: CGSize(width: 0, height: 0),
                          blur: blurRadius,
                          color: lineColor.withAlphaComponent(0.6).cgColor)
            lineColor.setStroke()
            path.lineWidth = (style == .mini ? 2.0 : 3.0)
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
            ctx.restoreGState()
        }

        // -- Pulsing end-dot at the latest point --
        // A small filled dot with a faint outer halo, like the Apple Stocks app.
        let dotRadius: CGFloat = (style == .mini ? 3.0 : 4.5)
        let haloRadius = dotRadius * 2.4
        let halo = NSBezierPath(
            ovalIn: NSRect(
                x: lastPoint.x - haloRadius,
                y: lastPoint.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )
        )
        lineColor.withAlphaComponent(0.22).setFill()
        halo.fill()

        let dot = NSBezierPath(
            ovalIn: NSRect(
                x: lastPoint.x - dotRadius,
                y: lastPoint.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
        )
        lineColor.setFill()
        dot.fill()
        // White ring for contrast
        NSColor.windowBackgroundColor.withAlphaComponent(0.7).setStroke()
        dot.lineWidth = 0.6
        dot.stroke()
    }

    // MARK: - Decorations

    private func drawFullDecorations(plot: NSRect, lo: Double, hi: Double, prevClose: Double?) {
        let grid = NSColor.separatorColor.withAlphaComponent(0.6)
        grid.setStroke()

        // Vertical gridlines at 09:30 (start), 11:30 (lunch), 13:00 (resume), 15:00 (close).
        let xMarks: [(Double, String)] = [
            (0,   "09:30"),
            (120, "11:30"),
            (120, "13:00"), // visually same x as lunch start
            (240, "15:00")
        ]
        var seenX = Set<CGFloat>()
        for (m, label) in xMarks {
            let xRel = CGFloat(m / 240.0)
            let x = plot.minX + plot.width * xRel
            // Skip drawing duplicate gridline at 11:30/13:00 (same x).
            let xKey = (x * 100).rounded() / 100
            let drawLine = !seenX.contains(xKey)
            seenX.insert(xKey)
            if drawLine {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: plot.minY))
                line.line(to: NSPoint(x: x, y: plot.maxY))
                line.lineWidth = 0.5
                line.stroke()
            }
            // Label below axis
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let size = str.size()
            // Lunch labels go on either side: 11:30 left of mark, 13:00 right of mark.
            let xText: CGFloat
            if label == "11:30" {
                xText = x - size.width - 1
            } else if label == "13:00" {
                xText = x + 2
            } else if label == "09:30" {
                xText = x - 2
            } else {
                xText = x - size.width + 2
            }
            str.draw(at: NSPoint(x: xText, y: plot.minY - size.height - 2))
        }

        // Horizontal baseline at prev close.
        if let pc = prevClose {
            let yRel = (pc - lo) / (hi - lo)
            let y = plot.minY + plot.height * CGFloat(yRel)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.setLineDash([2.0, 3.0], count: 2, phase: 0)
            line.lineWidth = 0.5
            line.stroke()

            // Y-axis labels: prev close in the middle, +/- max% at top/bottom
            let pctMax = ((hi - pc) / pc) * 100
            let topPct = String(format: "+%.2f%%", pctMax)
            let botPct = String(format: "-%.2f%%", pctMax)
            let mid = String(format: "%.2f", pc)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let neonRed = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.22, alpha: 1.0)
            let neonGreen = NSColor(calibratedRed: 0.19, green: 0.84, blue: 0.29, alpha: 1.0)
            for (text, ry, color) in [
                (topPct, 1.0, neonRed),
                (mid,    yRel, NSColor.secondaryLabelColor),
                (botPct, 0.0, neonGreen)
            ] as [(String, Double, NSColor)] {
                var attrs = labelAttrs
                attrs[.foregroundColor] = color
                let str = NSAttributedString(string: text, attributes: attrs)
                let size = str.size()
                let yLabel = plot.minY + plot.height * CGFloat(ry) - size.height / 2
                str.draw(at: NSPoint(x: plot.minX - size.width - 2, y: yLabel))
            }
        }
    }

    private func drawNoDataPlaceholder(in rect: NSRect) {
        let str = NSAttributedString(string: "暂无分时数据 / no minute data yet", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}


/// macOS 12/13 compatibility: NSBezierPath only exposes `cgPath` from macOS 14.
/// This extension manually builds an equivalent CGPath.
private extension NSBezierPath {
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<self.elementCount {
            let type = self.element(at: i, associatedPoints: &pts)
            switch type {
            case .moveTo:
                path.move(to: pts[0])
            case .lineTo:
                path.addLine(to: pts[0])
            case .curveTo:
                path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath:
                path.closeSubpath()
            case .quadraticCurveTo:
                path.addQuadCurve(to: pts[1], control: pts[0])
            case .cubicCurveTo:
                path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            @unknown default:
                break
            }
        }
        return path
    }
}
