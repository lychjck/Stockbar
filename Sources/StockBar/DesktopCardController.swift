import AppKit

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

    /// Fixed card width — matches `WatchlistRowView`'s natural layout (380pt).
    static let cardWidth: CGFloat = 380

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

    var isVisible: Bool { window?.isVisible ?? false }

    init() {
        cardView.onClose = { [weak self] in
            self?.hide()
            self?.onClose?()
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
        guard abs(frame.height - targetHeight) > 0.5 else { return }
        let topY = frame.maxY
        frame.size.height = targetHeight
        frame.origin.y = topY - targetHeight
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Persistence

    private func saveOrigin(_ origin: NSPoint) {
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: Self.originKey)
    }

    private func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return NSPoint(x: parts[0], y: parts[1])
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

    private let header = HeaderDragView()
    private let titleLabel = NSTextField(labelWithString: "StockBar")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let rowsStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "暂无关注标的")

    // Reused rows, keyed by normalized symbol.
    private var rowViews: [String: WatchlistRowView] = [:]
    private var currentSymbols: [String] = []

    // Layout metrics.
    private let topInset: CGFloat = 8
    private let headerHeight: CGFloat = 24
    private let headerGap: CGFloat = 4
    private let rowHeight: CGFloat = 40
    private let bottomInset: CGFloat = 8

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
            widthAnchor.constraint(equalToConstant: DesktopCardController.cardWidth),

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

            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: headerGap),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: headerGap),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.heightAnchor.constraint(equalToConstant: rowHeight),
        ])
    }

    /// Preferred total height for the current item count.
    func preferredHeight() -> CGFloat {
        let bodyRows = max(items.count, 1)   // empty state still reserves one row
        return topInset + headerHeight + headerGap + CGFloat(bodyRows) * rowHeight + bottomInset
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
            rebuildRows(for: [])
            return
        }
        emptyLabel.isHidden = true
        rowsStack.isHidden = false

        let symbols = items.map { $0.normalizedSymbol }
        if symbols != currentSymbols {
            rebuildRows(for: items)
            currentSymbols = symbols
        }

        for item in items {
            let sym = item.normalizedSymbol
            guard let row = rowViews[sym] else { continue }
            let q = quotes[sym]
            row.update(item: item, quote: q, minutes: minutes[sym] ?? [], prevClose: q?.prevClose)
        }
    }

    private func rebuildRows(for items: [WatchItem]) {
        for v in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()

        for item in items {
            let row = WatchlistRowView(item: item)
            // The desktop card is read-only: no click/drag/delete wiring.
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
