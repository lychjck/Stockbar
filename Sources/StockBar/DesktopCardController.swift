import AppKit
import StockCore

/// A borderless, draggable, glassmorphic floating window that shows the
/// watchlist as a compact desktop widget.
///
/// It is fully independent of the menu-bar popover but renders the *same* data
/// (quotes / minutes), which `AppDelegate` pushes in via `update(...)`.
/// Reuses `WatchlistRowView` so the row look matches the popover exactly.
@MainActor
final class DesktopCardController {

    // Persisted state keys.
    private static let visibleKey = "desktopCard.visible"
    private static let originKey  = "desktopCard.origin"   // "x,y"

    /// Card width follows the same persisted panel width used by the popover.
    static var cardWidth: CGFloat { PopoverController.savedPanelWidth }

    private var window: DesktopCardWindow?
    private let cardView = DesktopCardView()

    // ---- Data mirror (set by AppDelegate before calling reload()).
    var items: [WatchItem] = []
    var quotes: [String: Quote] = [:]
    var minutes: [String: [MinutePoint]] = [:]
    var lastUpdated: Date?
    var marketPhase: MarketHours.Phase = .preMarket

    /// Fired when the user clicks the card's close button (so AppDelegate can
    /// keep any toggle state in sync). The controller has already hidden itself.
    var onClose: (() -> Void)?

    /// Fired when the user selects/deselects a row, so AppDelegate can fetch
    /// that symbol's minute series. nil = detail collapsed.
    var onSelectRow: ((WatchItem?) -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        cardView.onClose = { [weak self] in
            self?.hide()
            self?.onClose?()
        }
        cardView.onSelectRow = { [weak self] item in
            self?.onSelectRow?(item)
        }
        cardView.onWidthChanged = { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.resizeToFit(window)
            self.saveOrigin(window.frame.origin)
        }
    }

    // MARK: - Visibility

    func show() {
        let win = window ?? makeWindow()
        window = win
        reload()                       // size + populate before showing
        win.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
    }

    func hide() {
        window?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Restore last-session visibility. Call once at launch.
    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.visibleKey) {
            show()
        }
    }

    // MARK: - Data

    /// Re-render from the current `items` / `quotes` / `minutes`. No-op while hidden.
    func reload() {
        guard let window, window.isVisible else { return }
        cardView.update(
            items: items,
            quotes: quotes,
            minutes: minutes,
            lastUpdated: lastUpdated,
            marketPhase: marketPhase
        )
        resizeToFit(window)
        saveOrigin(window.frame.origin)
    }

    // MARK: - Window plumbing

    private func makeWindow() -> DesktopCardWindow {
        let win = DesktopCardWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.hidesOnDeactivate = false

        // Glassmorphic backing.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false

        cardView.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: blur.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        win.contentView = blur

        // Resize the window when a row is expanded/collapsed.
        cardView.onLayoutChanged = { [weak self, weak win] in
            guard let self, let win else { return }
            self.resizeToFit(win)
        }

        // Restore saved origin, else top-right corner of the main screen.
        if let origin = savedOrigin() {
            win.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: vf.maxX - Self.cardWidth - 24, y: vf.maxY - 240))
        }
        return win
    }

    /// Grow/shrink the window to the card's preferred height, keeping the top
    /// edge anchored (so it expands downward as rows are added).
    private func resizeToFit(_ window: NSWindow) {
        let targetHeight = cardView.preferredHeight()
        var frame = window.frame
        let targetWidth = Self.cardWidth
        guard abs(frame.height - targetHeight) > 0.5 || abs(frame.width - targetWidth) > 0.5 else { return }
        let topY = frame.maxY
        frame.size.width = targetWidth
        frame.size.height = targetHeight
        frame.origin.y = topY - targetHeight
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Persistence

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: Self.originKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: Self.originKey), !s.isEmpty else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let origin = NSPoint(x: parts[0], y: parts[1])
        // Validate that the origin is within the union of all available screens.
        // If not (e.g. external monitor disconnected), return nil so the window
        // falls back to the default top-right position.
        let visible = NSScreen.screens.map(\.visibleFrame).reduce(NSRect.null) { $0.union($1) }
        guard visible.contains(origin) else { return nil }
        return origin
    }
}

// MARK: - Window

/// Borderless non-activating panel. Stays visible without stealing key focus
/// from the user's frontmost app.
final class DesktopCardWindow: NSPanel {
    override var canBecomeKey: Bool { true }      // allow the close button to work
    override var canBecomeMain: Bool { false }
}

// MARK: - Card view

/// The card's content: a small drag handle / header (title · updated time ·
/// phase · close button) on top of a vertical stack of `WatchlistRowView`s.
@MainActor
final class DesktopCardView: NSView {

    var onClose: (() -> Void)?

    /// Fired when the user selects/deselects a row (to fetch its minute series).
    /// nil means the detail was collapsed.
    var onSelectRow: ((WatchItem?) -> Void)?

    /// Fired when the card's content height changes (row selected/deselected),
    /// so the controller can resize the window.
    var onLayoutChanged: (() -> Void)?
    var onWidthChanged: ((CGFloat) -> Void)?

    private let header = HeaderDragView()
    private let titleLabel = NSTextField(labelWithString: "StockBar")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let resizeHandle = WidthResizeHandleView()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无关注标的")

    // Inline detail (full intraday chart for the selected row).
    private let detailContainer = NSView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSubtitle = NSTextField(labelWithString: "")
    private let detailChart = ChartView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
    private var detailWidthConstraint: NSLayoutConstraint?
    private var selectedSymbol: String?

    // Reused rows, keyed by normalized symbol.
    private var rowViews: [String: WatchlistRowView] = [:]
    private var currentSymbols: [String] = []

    // Last data snapshot, so the detail can refresh on quote ticks.
    private var quotes: [String: Quote] = [:]
    private var minutes: [String: [MinutePoint]] = [:]

    // Layout metrics.
    private let topInset: CGFloat = 8
    private let headerHeight: CGFloat = 24
    private let headerGap: CGFloat = 4
    private let rowHeight: CGFloat = 40
    private let bottomInset: CGFloat = 8
    private let detailHeight: CGFloat = 200

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        // ---- Header (also the drag handle).
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(cfg)
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "隐藏桌面卡片"
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleLabel)
        header.addSubview(statusLabel)
        header.addSubview(closeButton)
        addSubview(header)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.toolTip = "拖动调整宽度"
        resizeHandle.currentWidth = { PopoverController.savedPanelWidth }
        resizeHandle.onWidthChanged = { [weak self] width in
            self?.setPanelWidth(width)
        }
        addSubview(resizeHandle)

        // ---- Rows.
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowsStack)

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: topInset),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),

            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: headerGap),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: headerGap),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.heightAnchor.constraint(equalToConstant: rowHeight),
        ])

        configureDetail()
    }

    /// Builds the inline detail container (title · subtitle · full chart). It is
    /// inserted into `rowsStack` below the selected row on demand.
    private func configureDetail() {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true

        detailTitle.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        detailTitle.textColor = .labelColor
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailTitle.drawsBackground = false
        detailTitle.isBezeled = false
        detailTitle.isEditable = false
        detailContainer.addSubview(detailTitle)

        let subDesc = NSFont.systemFont(ofSize: 12, weight: .semibold).fontDescriptor.withDesign(.rounded)
        if let d = subDesc, let f = NSFont(descriptor: d, size: 12) {
            detailSubtitle.font = f
        } else {
            detailSubtitle.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        }
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.translatesAutoresizingMaskIntoConstraints = false
        detailSubtitle.drawsBackground = false
        detailSubtitle.isBezeled = false
        detailSubtitle.isEditable = false
        detailContainer.addSubview(detailSubtitle)

        detailChart.style = .full
        detailChart.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailChart)

        NSLayoutConstraint.activate([
            detailContainer.heightAnchor.constraint(equalToConstant: detailHeight),

            detailTitle.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 6),
            detailTitle.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 16),

            detailSubtitle.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 8),
            detailSubtitle.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -16),

            detailChart.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 4),
            detailChart.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 8),
            detailChart.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -8),
            detailChart.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -8),
        ])
    }

    /// Preferred total height for the current item count.
    func preferredHeight() -> CGFloat {
        let bodyRows = max(items.count, 1)   // empty state still reserves one row
        let detail = (selectedSymbol != nil) ? detailHeight : 0
        return topInset + headerHeight + headerGap + CGFloat(bodyRows) * rowHeight + detail + bottomInset
    }

    private func setPanelWidth(_ width: CGFloat) {
        PopoverController.savePanelWidth(width)
        onWidthChanged?(PopoverController.savedPanelWidth)
    }

    // Keep a copy so preferredHeight can read it.
    private var items: [WatchItem] = []

    func update(
        items: [WatchItem],
        quotes: [String: Quote],
        minutes: [String: [MinutePoint]],
        lastUpdated: Date?,
        marketPhase: MarketHours.Phase
    ) {
        self.items = items
        self.quotes = quotes
        self.minutes = minutes

        // Header status line: "14:21:08 · ● 下午盘".
        var status = ""
        if let lastUpdated {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            status = f.string(from: lastUpdated)
        }
        status += status.isEmpty ? marketPhase.label : " · \(marketPhase.label)"
        statusLabel.stringValue = status

        // Empty state.
        if items.isEmpty {
            emptyLabel.isHidden = false
            rowsStack.isHidden = true
            selectedSymbol = nil
            rebuildRows(for: [])
            return
        }
        emptyLabel.isHidden = true
        rowsStack.isHidden = false

        let symbols = items.map { $0.normalizedSymbol }
        if symbols != currentSymbols {
            rebuildRows(for: items)
            currentSymbols = symbols
            // The selected symbol may have disappeared from the list.
            if let sel = selectedSymbol, rowViews[sel] == nil {
                selectedSymbol = nil
            }
            relocateDetail()
        }

        for item in items {
            let sym = item.normalizedSymbol
            guard let row = rowViews[sym] else { continue }
            let q = quotes[sym]
            row.update(item: item, quote: q, minutes: minutes[sym] ?? [], prevClose: q?.prevClose)
            row.isSelected = (sym == selectedSymbol)
        }

        if selectedSymbol != nil {
            updateDetail()
        }
    }

    /// Toggle the inline detail chart for a row.
    private func toggleSelect(_ item: WatchItem) {
        let sym = item.normalizedSymbol
        selectedSymbol = (selectedSymbol == sym) ? nil : sym
        for (k, row) in rowViews { row.isSelected = (k == selectedSymbol) }
        relocateDetail()
        if selectedSymbol != nil { updateDetail() }
        onSelectRow?(selectedSymbol == nil ? nil : item)
        onLayoutChanged?()
    }

    /// Detach the detail container, then re-insert it right below the selected row.
    private func relocateDetail() {
        if detailContainer.superview != nil {
            rowsStack.removeArrangedSubview(detailContainer)
            detailContainer.removeFromSuperview()
        }
        guard let sym = selectedSymbol, let row = rowViews[sym] else { return }
        let arranged = rowsStack.arrangedSubviews
        guard let idx = arranged.firstIndex(of: row) else { return }
        rowsStack.insertArrangedSubview(detailContainer, at: idx + 1)
        if detailWidthConstraint == nil {
            detailWidthConstraint = detailContainer.widthAnchor.constraint(equalTo: rowsStack.widthAnchor)
        }
        detailWidthConstraint?.isActive = true
    }

    /// Fill the detail title/subtitle/chart from the latest snapshot.
    private func updateDetail() {
        guard let sym = selectedSymbol,
              let item = items.first(where: { $0.normalizedSymbol == sym })
        else { return }
        let q = quotes[sym]
        let pts = minutes[sym] ?? []

        let titleText: String
        if !item.alias.isEmpty {
            titleText = "\(item.alias)  \(item.code)"
        } else if let q {
            titleText = "\(q.name)  \(item.code)"
        } else {
            titleText = item.code
        }
        detailTitle.stringValue = titleText

        if let q {
            let pctStr = (q.pct >= 0 ? "+" : "-") + String(format: "%.2f%%", abs(q.pct))
            detailSubtitle.stringValue = "\(formatPrice(q.price))   \(pctStr)   prev \(formatPrice(q.prevClose))"
            let neonRed = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.22, alpha: 1.0)
            let neonGreen = NSColor(calibratedRed: 0.19, green: 0.84, blue: 0.29, alpha: 1.0)
            detailSubtitle.textColor = q.pct > 0 ? neonRed : (q.pct < 0 ? neonGreen : .secondaryLabelColor)
        } else {
            detailSubtitle.stringValue = "n/a"
            detailSubtitle.textColor = .secondaryLabelColor
        }

        detailChart.prevClose = q?.prevClose
        detailChart.currentPrice = q?.price
        detailChart.points = pts
    }

    private func formatPrice(_ v: Double) -> String {
        return abs(v) < 100 ? String(format: "%.3f", v) : String(format: "%.2f", v)
    }

    private func rebuildRows(for items: [WatchItem]) {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()

        for item in items {
            let row = WatchlistRowView(item: item)
            // The desktop card supports click-to-expand the intraday chart, but
            // no drag-reorder / delete wiring.
            row.onClick = { [weak self] tapped in self?.toggleSelect(tapped) }
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            rowViews[item.normalizedSymbol] = row
        }
        currentSymbols = items.map { $0.normalizedSymbol }
    }

    @objc private func handleClose() { onClose?() }
}

// MARK: - Drag handle

/// A plain view whose only job is to let the user drag the whole window by the
/// header area (in addition to `isMovableByWindowBackground`).
final class HeaderDragView: NSView {
    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
