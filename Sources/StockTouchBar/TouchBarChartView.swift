import AppKit
import StockCore

/// Minimal minute-level line chart sized for the 30pt-tall Touch Bar row.
///
/// Renders one line for the day's prices plus a dashed horizontal baseline at
/// previous close so the user can tell up/down at a glance. Vertical range is
/// `min..max` of the day's prices, padded to at least 0.5% of prev-close so a
/// completely flat stock still produces a visible line.
final class TouchBarChartView: NSView {

    var points: [MinutePoint] = [] {
        didSet { needsDisplay = true }
    }

    var quote: Quote? {
        didSet { needsDisplay = true }
    }

    /// Colors used for the line. CN convention: up = red, down = green.
    var upColor: NSColor = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.25, alpha: 1.0)
    var downColor: NSColor = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1.0)

    override var isFlipped: Bool { false }
    /// Reported wide on purpose: the Touch Bar app region is ~880pt, and we
    /// want this view to absorb whatever space the other items (back arrow,
    /// label, close) don't claim. Paired with a low horizontal
    /// content-hugging priority so AppKit prefers to stretch us, not them.
    override var intrinsicContentSize: NSSize { NSSize(width: 720, height: 30) }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let width = bounds.width
        let height = bounds.height

        // Empty / loading placeholder.
        guard points.count >= 2, let prevClose = quote?.prevClose, prevClose > 0 else {
            let label = "—"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: NSPoint(x: (width - size.width) / 2, y: (height - size.height) / 2),
                withAttributes: attrs
            )
            return
        }

        // Vertical range: at least ±0.25% of prev-close so a flat line is visible.
        let prices = points.map { $0.price }
        let lo = prices.min() ?? prevClose
        let hi = prices.max() ?? prevClose
        let minPad = prevClose * 0.0025
        let center = (lo + hi) / 2
        var halfSpan = max((hi - lo) / 2, minPad)
        // Always include prev-close in the visible band — the baseline must
        // sit inside the chart, not float at the edge.
        halfSpan = max(halfSpan, abs(center - prevClose) + minPad)
        let yMin = center - halfSpan
        let yMax = center + halfSpan

        func y(for price: Double) -> CGFloat {
            // 1pt top/bottom inset so strokes don't get clipped at the edges.
            let inset: CGFloat = 1.5
            let usable = height - 2 * inset
            return inset + CGFloat((price - yMin) / (yMax - yMin)) * usable
        }
        // Full CN trading day = 240 tradable minutes (09:30–11:30 morning +
        // 13:00–15:00 afternoon, lunch break compressed). Positioning x by
        // absolute minutes-from-open — instead of `index / count` — means
        // 5 minutes of data occupy the leftmost ~2% of the strip, not the
        // whole width; the chart grows through the day.
        let xMax: CGFloat = 240
        func x(for point: MinutePoint) -> CGFloat {
            let inset: CGFloat = 2
            let usable = width - 2 * inset
            return inset + CGFloat(point.minutesFromOpen) / xMax * usable
        }

        // ---- Dashed baseline at prev-close.
        let baselinePath = NSBezierPath()
        let bY = y(for: prevClose)
        baselinePath.move(to: NSPoint(x: 0, y: bY))
        baselinePath.line(to: NSPoint(x: width, y: bY))
        baselinePath.lineWidth = 0.5
        let dashPattern: [CGFloat] = [2.5, 2.5]
        baselinePath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        baselinePath.stroke()

        // ---- Price line.
        let pct = quote?.pct ?? 0
        let lineColor: NSColor = pct > 0 ? upColor : (pct < 0 ? downColor : .labelColor)

        let linePath = NSBezierPath()
        for (i, p) in points.enumerated() {
            let pt = NSPoint(x: x(for: p), y: y(for: p.price))
            if i == 0 { linePath.move(to: pt) }
            else      { linePath.line(to: pt) }
        }
        linePath.lineWidth = 1.4
        linePath.lineJoinStyle = .round
        linePath.lineCapStyle = .round
        lineColor.setStroke()
        linePath.stroke()
    }
}
