import AppKit

/// One row in the popover list:  [alias / code]  [name]  [price]  [pct]  [mini sparkline]
/// Click toggles selection. Selected rows highlight; the controller below shows the full chart.
final class WatchlistRowView: NSView {
    var item: WatchItem
    var quote: Quote?
    var minutePoints: [MinutePoint] = [] {
        didSet { sparkline.points = minutePoints }
    }
    var prevClose: Double? {
        didSet { sparkline.prevClose = prevClose }
    }

    var isSelected: Bool = false { didSet { needsDisplay = true } }

    /// Called on click with the row's item.
    var onClick: ((WatchItem) -> Void)?

    /// Drag-reorder lifecycle. The popover handles the actual reordering;
    /// the row just reports cursor events relative to the screen.
    /// onDragBegan: user pressed and started moving past the threshold.
    /// onDragMoved:  user moved while dragging; arg is current mouse Y in row's superview coords.
    /// onDragEnded:  user released. true = a drag actually happened (so the click should be suppressed).
    var onDragBegan: ((WatchlistRowView) -> Void)?
    var onDragMoved: ((WatchlistRowView, NSPoint) -> Void)?
    var onDragEnded: ((WatchlistRowView, Bool) -> Void)?

    /// Called when the user clicks the row's hover-revealed delete button.
    var onDelete: ((WatchItem) -> Void)?

    private let aliasLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let pctLabel = NSTextField(labelWithString: "")
    private let sparkline = ChartView(frame: .zero)

    init(item: WatchItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        wantsLayer = true
        sparkline.style = .mini

        for field in [aliasLabel, codeLabel, priceLabel, pctLabel] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.drawsBackground = false
            field.isBezeled = false
            field.isEditable = false
            field.cell?.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        // Alias uses the system font (semibold) — letters mix with CJK best.
        aliasLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        // Code is small + secondary.
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.font = Self.monoFont(size: 11, weight: .regular)
        // Numbers use the rounded design so they look more modern + match Stocks app.
        priceLabel.font = Self.roundedDigitFont(size: 13, weight: .medium)
        pctLabel.font = Self.roundedDigitFont(size: 13, weight: .semibold)

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sparkline)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            aliasLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            aliasLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            aliasLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            codeLabel.leadingAnchor.constraint(equalTo: aliasLabel.trailingAnchor, constant: 8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            codeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 60),

            // Sparkline pinned to the right; before it: pct + price (right-aligned)
            sparkline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sparkline.centerYAnchor.constraint(equalTo: centerYAnchor),
            sparkline.widthAnchor.constraint(equalToConstant: 70),
            sparkline.heightAnchor.constraint(equalToConstant: 20),

            pctLabel.trailingAnchor.constraint(equalTo: sparkline.leadingAnchor, constant: -10),
            pctLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pctLabel.widthAnchor.constraint(equalToConstant: 64),

            priceLabel.trailingAnchor.constraint(equalTo: pctLabel.leadingAnchor, constant: -10),
            priceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            priceLabel.widthAnchor.constraint(equalToConstant: 64),
        ])
        priceLabel.alignment = .right
        pctLabel.alignment = .right

        applyContent()
    }

    /// SF Pro Rounded with tabular numbers — matches Apple Stocks app.
    private static func roundedDigitFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        // Force tabular figures so numbers line up across rows.
        let tabular = descriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]
        ])
        return NSFont(descriptor: tabular, size: size) ?? base
    }

    private static func monoFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func update(item: WatchItem, quote: Quote?, minutes: [MinutePoint], prevClose: Double?) {
        self.item = item
        self.quote = quote
        self.prevClose = prevClose
        self.minutePoints = minutes
        applyContent()
    }

    private func applyContent() {
        let aliasText: String
        if !item.alias.isEmpty {
            aliasText = item.alias
        } else if let q = quote {
            aliasText = q.name
        } else {
            aliasText = item.code
        }
        aliasLabel.stringValue = aliasText
        codeLabel.stringValue = item.code

        if let q = quote {
            priceLabel.stringValue = formatPrice(q.price)
            pctLabel.stringValue = formatPct(q.pct)
            // CN convention: red up, green down.
            let color: NSColor = q.pct > 0 ? .systemRed : (q.pct < 0 ? .systemGreen : .secondaryLabelColor)
            pctLabel.textColor = color
            priceLabel.textColor = .labelColor
            toolTip = "high \(formatPrice(q.high)) · low \(formatPrice(q.low)) · prev \(formatPrice(q.prevClose))"
            // Keep the sparkline's color in sync with the live pct — pass the
            // realtime price as the "latest" reference (the minute series can
            // lag the quote by up to 30 s).
            sparkline.currentPrice = q.price
        } else {
            priceLabel.stringValue = "—"
            pctLabel.stringValue = "—"
            pctLabel.textColor = .secondaryLabelColor
            toolTip = nil
            sparkline.currentPrice = nil
        }
    }

    private func formatPrice(_ v: Double) -> String {
        return abs(v) < 100 ? String(format: "%.3f", v) : String(format: "%.2f", v)
    }

    private func formatPct(_ v: Double) -> String {
        let s = v > 0 ? "+" : (v < 0 ? "-" : "")
        return "\(s)\(String(format: "%.2f", abs(v)))%"
    }

    // MARK: - Selection / hover background

    override func draw(_ dirtyRect: NSRect) {
        // Slightly inset rounded "capsule" highlight when selected/hovering — this
        // looks calmer than a full-bleed fill.
        let inset = NSRect(
            x: bounds.minX + 4,
            y: bounds.minY + 2,
            width: bounds.width - 8,
            height: bounds.height - 4
        )
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
            path.fill()
        } else if isHovering {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.55).setFill()
            path.fill()
        }
    }

    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLocation else { return }
        let curr = event.locationInWindow
        let dy = curr.y - start.y
        let dx = curr.x - start.x
        if !isDragging {
            // Enter drag mode after a small threshold to avoid jitter on plain clicks.
            if abs(dy) > 4 || abs(dx) > 6 {
                isDragging = true
                onDragBegan?(self)
            } else {
                return
            }
        }
        // Translate window coordinate to superview (rowsStack) coordinate so
        // the controller can decide which neighbour to swap with.
        if let sv = superview {
            let p = sv.convert(curr, from: nil)
            onDragMoved?(self, p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = isDragging
        if didDrag {
            onDragEnded?(self, true)
        } else {
            // No drag happened — treat as a click (toggle selection).
            onClick?(item)
        }
        dragStartLocation = nil
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let label = item.alias.isEmpty ? item.code : "\(item.alias) \(item.code)"
        let menu = NSMenu()
        let delete = NSMenuItem(title: "删除「\(label)」", action: #selector(menuDelete), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuDelete() {
        onDelete?(item)
    }

    private var dragStartLocation: NSPoint?
    private var isDragging: Bool = false
}
