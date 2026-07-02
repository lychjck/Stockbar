import AppKit
import StockCore

/// View controller backing the NSPopover content.
/// Layout (top → bottom):
///   - Header (refresh time + market phase + refresh button + open-config + quit)
///   - Watchlist row stack (one WatchlistRowView per WatchItem)
///   - Detail area (full ChartView for selected row + symbol info)
@MainActor
final class PopoverController: NSViewController, NSTextFieldDelegate {

    // MARK: - Public state

    var items: [WatchItem] = []
    var quotes: [String: Quote] = [:]                 // key: normalizedSymbol
    var minutes: [String: [MinutePoint]] = [:]        // key: normalizedSymbol
    var lastUpdated: Date?
    var marketPhase: MarketHours.Phase = .preMarket

    /// Notified when the user clicks an action button in the header.
    var onRefresh: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSelectionChanged: ((WatchItem?) -> Void)?
    /// Called when the user submits the add-bar with a 6-digit code and optional alias.
    var onAddItem: ((_ code: String, _ alias: String?) -> Void)?
    /// Called when the user clicks the row's right-side delete button.
    var onRemoveItem: ((_ code: String) -> Void)?
    /// Called after a drag-reorder is committed. Argument is the new list order
    /// of normalized symbols.
    var onReorder: ((_ orderedSymbols: [String]) -> Void)?

    /// Called when the user clicks the header's desktop-card toggle button.
    var onToggleDesktopCard: (() -> Void)?

    /// Called when the user picks a different sort mode from the header menu.
    /// `AppDelegate` uses this to also re-sort the desktop card.
    var onSortModeChanged: ((SortMode) -> Void)?

    /// Called when the user clicks the header's preferences button.
    var onOpenPreferences: (() -> Void)?

    /// Weak ref to the hosting popover so we can resize it when content changes.
    weak var popover: NSPopover?

    private(set) var selectedSymbol: String?

    // MARK: - Subviews

    private let headerLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let configButton = NSButton()
    private let preferencesButton = NSButton()
    private let quitButton = NSButton()
    private let addToggleButton = NSButton()
    private let desktopCardButton = NSButton()
    private let sortButton = NSButton()
    private let resizeHandle = WidthResizeHandleView()

    // ---- Add bar (collapsible row below header)
    private let addBar = NSStackView()
    private let codeField = NSTextField()
    private let aliasField = NSTextField()
    private let addSubmitButton = NSButton()
    private let addErrorLabel = NSTextField(labelWithString: "")
    private var isAddBarVisible = false
    private var addBarCollapsedHeight: NSLayoutConstraint?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let rowsStack = NSStackView()       // contains row views (and detail view inserted)
    private let detailContainer = NSView()
    private let detailChart = ChartView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSubtitle = NSTextField(labelWithString: "")
    private let detailStats = NSTextField(labelWithString: "")

    private var rowViews: [String: WatchlistRowView] = [:]   // key: normalizedSymbol
    private var detailWidthConstraint: NSLayoutConstraint?

    /// `items` filtered/sorted for rendering. The raw `items` array is kept in
    /// the source order from disk, so `onReorder` can keep mutating the file
    /// without fighting whatever transient view sort is active. Derived from
    /// `items` + `quotes` + `SortMode.current` inside `reload()`.
    private var displayItems: [WatchItem] = []

    private static let widthKey = "StockBar.panelWidth"
    private static let defaultWidth: CGFloat = 520
    private static let minWidth: CGFloat = 420
    private static let maxWidth: CGFloat = 760

    static var savedPanelWidth: CGFloat {
        let raw = UserDefaults.standard.double(forKey: widthKey)
        let value = raw > 0 ? CGFloat(raw) : defaultWidth
        return min(max(value, minWidth), maxWidth)
    }

    static func savePanelWidth(_ width: CGFloat) {
        let clamped = min(max(width, minWidth), maxWidth)
        UserDefaults.standard.set(Double(clamped), forKey: widthKey)
    }

    // MARK: - View lifecycle

    override func loadView() {
        // Use a vibrant blurred background so the popover blends with the
        // system menu bar / desktop wallpaper.
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.savedPanelWidth, height: 480))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = NSAppearance(named: .vibrantDark) // Force dark mode for neon aesthetic
        root.wantsLayer = true
        self.view = root

        // ---- Header bar
        let headerBar = NSStackView()
        headerBar.orientation = .horizontal
        headerBar.spacing = 8
        headerBar.alignment = .centerY
        headerBar.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 10, right: 16)
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = NSFont.systemFont(ofSize: 11)
        headerLabel.textColor = .secondaryLabelColor
        phaseLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        phaseLabel.textColor = .secondaryLabelColor

        configureHeaderButton(refreshButton, symbol: "arrow.clockwise", tooltip: "Refresh", action: #selector(handleRefresh))
        configureHeaderButton(addToggleButton, symbol: "plus.circle", tooltip: "Add stock / ETF", action: #selector(handleToggleAddBar))
        configureHeaderButton(desktopCardButton, symbol: "macwindow.on.rectangle", tooltip: "显示 / 隐藏桌面卡片", action: #selector(handleToggleDesktopCard))
        configureHeaderButton(sortButton, symbol: SortMode.current.symbol, tooltip: "排序", action: #selector(handleSort))
        applySortButtonTint()
        configureHeaderButton(preferencesButton, symbol: "gearshape", tooltip: "设置", action: #selector(handleOpenPreferences))
        configureHeaderButton(configButton, symbol: "doc.text", tooltip: "Open watchlist.json", action: #selector(handleOpenConfig))
        configureHeaderButton(quitButton, symbol: "power", tooltip: "Quit StockBar", action: #selector(handleQuit))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        headerBar.addArrangedSubview(headerLabel)
        headerBar.addArrangedSubview(phaseLabel)
        headerBar.addArrangedSubview(spacer)
        headerBar.addArrangedSubview(sortButton)
        headerBar.addArrangedSubview(addToggleButton)
        headerBar.addArrangedSubview(desktopCardButton)
        headerBar.addArrangedSubview(refreshButton)
        headerBar.addArrangedSubview(preferencesButton)
        headerBar.addArrangedSubview(configButton)
        headerBar.addArrangedSubview(quitButton)

        root.addSubview(headerBar)

        // Hairline separator under the header bar.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        // ---- Add bar (hidden by default; toggled by the + button)
        configureAddBar()
        root.addSubview(addBar)

        // ---- Scrollable list
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(rowsStack)

        scrollView.documentView = contentStack
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Use a flipped clip view so y=0 is the top — makes scrollToVisible behave
        // intuitively (target.minY = top of target).
        let flippedClip = FlippedClipView()
        flippedClip.drawsBackground = false
        scrollView.contentView = flippedClip
        scrollView.documentView = contentStack
        root.addSubview(scrollView)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.toolTip = "拖动调整宽度"
        resizeHandle.currentWidth = { Self.savedPanelWidth }
        resizeHandle.onWidthChanged = { [weak self] width in
            self?.setPanelWidth(width)
        }
        root.addSubview(resizeHandle)

        // ---- Detail area (chart for the selected row).
        // It lives as an *inline* arranged subview inserted into rowsStack right
        // after the selected row. Not retained anywhere else — it's only attached
        // to the stack while a row is selected.
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true

        detailTitle.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        detailTitle.textColor = .labelColor
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailTitle)

        // Use rounded tabular digits for the subtitle (price · pct · prev).
        let subDesc = NSFont.systemFont(ofSize: 13, weight: .semibold)
            .fontDescriptor
            .withDesign(.rounded)
        if let d = subDesc, let f = NSFont(descriptor: d, size: 13) {
            detailSubtitle.font = f
        } else {
            detailSubtitle.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailSubtitle)

        // Compact two-line stats grid (今开/最高/最低 · 振幅/量/额/换手/PE).
        detailStats.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailStats.textColor = .secondaryLabelColor
        detailStats.maximumNumberOfLines = 2
        detailStats.lineBreakMode = .byWordWrapping
        detailStats.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailStats)

        detailChart.style = .full
        detailChart.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailChart)

        // ---- Constraints
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: root.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            separator.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            separator.heightAnchor.constraint(equalToConstant: 1),

            addBar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            addBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            addBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: addBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            resizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            // detailContainer is its own height when inserted into rowsStack.
            detailContainer.heightAnchor.constraint(equalToConstant: 252),

            detailTitle.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 6),
            detailTitle.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 12),

            detailSubtitle.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 6),
            detailSubtitle.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -12),

            detailStats.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 3),
            detailStats.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 12),
            detailStats.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -12),

            detailChart.topAnchor.constraint(equalTo: detailStats.bottomAnchor, constant: 4),
            detailChart.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 4),
            detailChart.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -4),
            detailChart.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -8),
        ])
    }

    private func configureHeaderButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Public refresh API

    /// Re-render the whole popover from current `items` / `quotes` / `minutes`.
    func reload() {
        // Recompute the sorted view first so every downstream renderer (row stack,
        // detail location, popover sizing) sees the same ordering for this tick.
        displayItems = SortMode.current.apply(to: items, quotes: quotes)
        rebuildRowsIfNeeded()
        // After a full rebuild the detail container has been detached, so re-attach
        // it under the currently selected row (no-op if nothing selected).
        relocateDetailContainer()
        for (sym, row) in rowViews {
            let q = quotes[sym]
            row.update(item: row.item, quote: q, minutes: minutes[sym] ?? [], prevClose: q?.prevClose)
        }
        // Drop selection if the previously selected symbol is no longer in the list.
        if let s = selectedSymbol, rowViews[s] == nil {
            selectedSymbol = nil
        }
        updateHeader()
        updateDetail()
        updatePopoverSize()
    }

    /// Compute a window height that fits the actual content
    /// (header + optional add-bar + N rows + optional inline detail), capped to 85% of screen.
    /// Updates the popover's contentSize so it animates to the new height.
    private func updatePopoverSize() {
        let rowsHeight = CGFloat(items.count) * 40
        let detailHeight: CGFloat = (selectedSymbol == nil) ? 0 : 252
        let listIdeal = rowsHeight + detailHeight
        let screenAvail = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let addBarHeight: CGFloat = isAddBarVisible ? 36 : 0
        // Reserve room for header (36) + add bar + bottom padding (8).
        let chrome: CGFloat = 36 + addBarHeight + 8
        let listMax = max(120, screenAvail - chrome)
        let listClamp = min(listIdeal, listMax)
        let total = chrome + max(listClamp, 28)
        let width = Self.savedPanelWidth
        let newSize = NSSize(width: width, height: total)
        preferredContentSize = newSize
        if let pop = popover, pop.contentSize != newSize {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                pop.contentSize = newSize
            })
        }
        var f = view.frame
        f.size = newSize
        view.frame = f
    }

    private func setPanelWidth(_ width: CGFloat) {
        Self.savePanelWidth(width)
        updatePopoverSize()
    }

    /// Update only the header (used when you don't have new data yet but time ticked).
    func updateHeader() {
        if let t = lastUpdated {
            headerLabel.stringValue = "Updated " + Self.timeFormatter.string(from: t)
        } else {
            headerLabel.stringValue = "Loading…"
        }
        phaseLabel.stringValue = humanPhase(marketPhase)
        phaseLabel.textColor = marketPhase.isLive ? NSColor.systemRed.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    private func humanPhase(_ p: MarketHours.Phase) -> String {
        switch p {
        case .weekend: return "周末休市"
        case .preMarket: return "盘前"
        case .morningSession: return "● 上午盘"
        case .lunchBreak: return "午休"
        case .afternoonSession: return "● 下午盘"
        case .postMarket: return "已收盘"
        }
    }

    private func rebuildRowsIfNeeded() {
        let desiredKeys = displayItems.map { $0.normalizedSymbol }
        let currentKeys = rowsStack.arrangedSubviews.compactMap { ($0 as? WatchlistRowView)?.item.normalizedSymbol }

        if desiredKeys == currentKeys {
            // Just re-bind items (in case alias changed).
            for (i, item) in displayItems.enumerated() {
                let sym = item.normalizedSymbol
                if let row = rowsStack.arrangedSubviews[i] as? WatchlistRowView {
                    row.item = item
                    rowViews[sym] = row
                }
            }
            return
        }

        // Otherwise rebuild from scratch.
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        for item in displayItems {
            let row = WatchlistRowView(item: item)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onClick = { [weak self] tapped in
                self?.toggleSelection(tapped)
            }
            row.onDragBegan = { [weak self] r in
                self?.dragBegan(row: r)
            }
            row.onDragMoved = { [weak self] r, p in
                self?.dragMoved(row: r, locationInStack: p)
            }
            row.onDragEnded = { [weak self] r, didDrag in
                self?.dragEnded(row: r, didDrag: didDrag)
            }
            row.onDelete = { [weak self] item in
                self?.confirmAndRemove(item: item)
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            rowViews[item.normalizedSymbol] = row
        }
    }

    private func toggleSelection(_ item: WatchItem) {
        let sym = item.normalizedSymbol
        if selectedSymbol == sym {
            selectedSymbol = nil
        } else {
            selectedSymbol = sym
        }
        for (k, row) in rowViews {
            row.isSelected = (k == selectedSymbol)
        }
        // Insert / remove the inline detail view in the rows stack.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            relocateDetailContainer()
            onSelectionChanged?(selectedSymbol == nil ? nil : item)
            // reload() will recompute popover size; the popover grows to include the
            // detail block so the selected row stays visible without manual scrolling.
            reload()
        })
    }

    /// Move (or remove) `detailContainer` so it sits immediately after the selected row.
    private func relocateDetailContainer() {
        // Always detach first, then re-attach if a row is selected.
        if detailContainer.superview != nil {
            rowsStack.removeArrangedSubview(detailContainer)
            detailContainer.removeFromSuperview()
        }
        guard let sym = selectedSymbol,
              let row = rowViews[sym]
        else { return }
        let arranged = rowsStack.arrangedSubviews
        guard let rowIndex = arranged.firstIndex(of: row) else { return }
        rowsStack.insertArrangedSubview(detailContainer, at: rowIndex + 1)
        if detailWidthConstraint == nil {
            detailWidthConstraint = detailContainer.widthAnchor.constraint(equalTo: rowsStack.widthAnchor)
        }
        detailWidthConstraint?.isActive = true
    }

    // MARK: - Drag-reorder

    /// Drag state. We don't mutate the stack while the user is dragging — instead
    /// we draw a "ghost" snapshot that follows the mouse, leaving the real row in
    /// place. On mouse-up we compute the target index and commit a single reorder.
    private var dragGhost: NSView?
    private var dragOriginalRow: WatchlistRowView?
    private var dragOriginalIndex: Int = 0

    private func dragBegan(row: WatchlistRowView) {
        // Drag-reorder only makes sense against the manual baseline. If the
        // user is currently looking at a view-sorted list, silently ignore —
        // the row's superficial drag state will clear on mouseUp.
        guard SortMode.current == .manual else { return }

        // If detail is open, collapse it first so the chart doesn't fight with
        // the drag overlay for popover height.
        if selectedSymbol != nil {
            selectedSymbol = nil
            for (_, r) in rowViews { r.isSelected = false }
            relocateDetailContainer()
            updatePopoverSize()
        }

        guard let stack = row.superview else { return }
        // Snapshot the row into a CGImage so we can show it on a layer.
        let bounds = row.bounds
        guard let rep = row.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        row.cacheDisplay(in: bounds, to: rep)

        // Build a floating overlay parked on the popover root view, so the stack
        // never has to re-layout to display it.
        let frameInRoot = stack.convert(row.frame, to: view)
        let ghost = NSView(frame: frameInRoot)
        ghost.wantsLayer = true
        ghost.layer?.contents = rep.cgImage
        ghost.layer?.contentsGravity = .resizeAspect
        ghost.alphaValue = 0.92
        ghost.layer?.shadowColor = NSColor.black.cgColor
        ghost.layer?.shadowOpacity = 0.25
        ghost.layer?.shadowRadius = 4
        ghost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        ghost.layer?.cornerRadius = 4
        view.addSubview(ghost, positioned: .above, relativeTo: nil)
        dragGhost = ghost

        dragOriginalRow = row
        let arranged = rowsStack.arrangedSubviews.compactMap { $0 as? WatchlistRowView }
        dragOriginalIndex = arranged.firstIndex(of: row) ?? 0

        // Dim the original so the user knows where it came from.
        row.alphaValue = 0.25
    }

    private func dragMoved(row: WatchlistRowView, locationInStack p: NSPoint) {
        guard let ghost = dragGhost else { return }
        // Convert the cursor to root-view coords; center the ghost on it.
        let pInRoot = rowsStack.convert(p, to: view)
        var origin = ghost.frame.origin
        origin.y = pInRoot.y - ghost.frame.height / 2
        // Clamp inside the root view so the ghost doesn't fly off the popover.
        let minY: CGFloat = 0
        let maxY = view.bounds.height - ghost.frame.height
        origin.y = max(minY, min(origin.y, maxY))
        ghost.frame.origin = origin
    }

    private func dragEnded(row: WatchlistRowView, didDrag: Bool) {
        defer {
            // Always tear down the ghost and restore the row's appearance.
            dragGhost?.removeFromSuperview()
            dragGhost = nil
            dragOriginalRow?.alphaValue = 1.0
            dragOriginalRow = nil
        }
        guard didDrag, let ghost = dragGhost else { return }

        // Decide insertion index from where the ghost ended up.
        let ghostCenterInRoot = NSPoint(x: ghost.frame.midX, y: ghost.frame.midY)
        let ghostCenterInStack = view.convert(ghostCenterInRoot, to: rowsStack)

        let arranged = rowsStack.arrangedSubviews.compactMap { $0 as? WatchlistRowView }
        var targetIdx = arranged.count - 1
        for (i, r) in arranged.enumerated() where r !== row {
            // FlippedClipView is in use, so smaller y is up; the first row whose
            // midY exceeds the ghost center is the row that should sit *below* the
            // dragged row in the new order — so insert at i.
            if ghostCenterInStack.y < r.frame.midY {
                targetIdx = i
                break
            }
        }

        if targetIdx != dragOriginalIndex {
            rowsStack.removeArrangedSubview(row)
            rowsStack.insertArrangedSubview(row, at: targetIdx)
        }

        let order = rowsStack.arrangedSubviews
            .compactMap { ($0 as? WatchlistRowView)?.item.normalizedSymbol }
        onReorder?(order)
    }

    private func updateDetail() {
        guard let sym = selectedSymbol,
              let item = items.first(where: { $0.normalizedSymbol == sym })
        else {
            // Nothing selected → the container has been removed by relocateDetailContainer.
            return
        }
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
            detailStats.stringValue = Self.statsText(for: q)
        } else {
            detailSubtitle.stringValue = "n/a"
            detailStats.stringValue = ""
        }

        detailChart.prevClose = q?.prevClose
        detailChart.currentPrice = q?.price
        detailChart.points = pts
    }

    private func formatPrice(_ v: Double) -> String {
        return abs(v) < 100 ? String(format: "%.3f", v) : String(format: "%.2f", v)
    }

    /// Build the two-line stats string shown under the price.
    /// Line 1: 今开 / 最高 / 最低.  Line 2: 振幅 / 量 / 额 (+ 换手 / PE when present).
    private static func statsText(for q: Quote) -> String {
        func price(_ v: Double) -> String { abs(v) < 100 ? String(format: "%.3f", v) : String(format: "%.2f", v) }
        let line1 = "今开 \(price(q.open))   最高 \(price(q.high))   最低 \(price(q.low))"
        var line2 = "振幅 \(String(format: "%.2f%%", q.amplitude))   量 \(formatVolume(q.volume))   额 \(formatAmount(q.amount))"
        if !q.isIndex, let t = q.turnoverRate, t > 0 {
            line2 += "   换手 \(String(format: "%.2f%%", t))"
        }
        if !q.isIndex, let pe = q.pe, pe > 0 {
            line2 += "   PE \(String(format: "%.1f", pe))"
        }
        return line1 + "\n" + line2
    }

    /// 成交量 in 手 (lots) → 万手 / 亿手.
    private static func formatVolume(_ lots: Double) -> String {
        if lots >= 1e8 { return String(format: "%.2f亿手", lots / 1e8) }
        if lots >= 1e4 { return String(format: "%.1f万手", lots / 1e4) }
        return String(format: "%.0f手", lots)
    }

    /// 成交额 in 万元 → 亿元 / 万元.
    private static func formatAmount(_ wan: Double) -> String {
        if wan >= 1e4 { return String(format: "%.2f亿", wan / 1e4) }
        return String(format: "%.0f万", wan)
    }

    // MARK: - Add bar

    private func configureAddBar() {
        addBar.translatesAutoresizingMaskIntoConstraints = false
        addBar.orientation = .horizontal
        addBar.spacing = 6
        addBar.alignment = .centerY
        addBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        addBar.isHidden = true   // collapsed by default
        // Keep the bar at zero height while hidden, so AutoLayout doesn't reserve
        // space for it in the popover. Deactivated when expanding.
        let h = addBar.heightAnchor.constraint(equalToConstant: 0)
        h.priority = .required
        h.isActive = true
        addBarCollapsedHeight = h

        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.placeholderString = "代码 e.g. 159770"
        codeField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        codeField.bezelStyle = .roundedBezel
        codeField.target = self
        codeField.action = #selector(submitAdd)
        codeField.delegate = self

        aliasField.translatesAutoresizingMaskIntoConstraints = false
        aliasField.placeholderString = "别名 (可选)"
        aliasField.font = NSFont.systemFont(ofSize: 12)
        aliasField.bezelStyle = .roundedBezel
        aliasField.target = self
        aliasField.action = #selector(submitAdd)
        aliasField.delegate = self

        addSubmitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubmitButton.title = "Add"
        addSubmitButton.bezelStyle = .rounded
        addSubmitButton.target = self
        addSubmitButton.action = #selector(submitAdd)

        addBar.addArrangedSubview(codeField)
        addBar.addArrangedSubview(aliasField)
        addBar.addArrangedSubview(addSubmitButton)

        NSLayoutConstraint.activate([
            codeField.widthAnchor.constraint(equalToConstant: 120),
            aliasField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    @objc private func handleToggleAddBar() {
        isAddBarVisible.toggle()
        addBar.isHidden = !isAddBarVisible
        // Toggle the zero-height constraint: collapsed when hidden, free when visible.
        addBarCollapsedHeight?.isActive = !isAddBarVisible
        // Update the toggle icon to indicate state.
        addToggleButton.image = NSImage(
            systemSymbolName: isAddBarVisible ? "xmark.circle" : "plus.circle",
            accessibilityDescription: isAddBarVisible ? "Cancel" : "Add stock / ETF"
        )
        if isAddBarVisible {
            view.window?.makeFirstResponder(codeField)
        } else {
            codeField.stringValue = ""
            aliasField.stringValue = ""
        }
        updatePopoverSize()
    }

    /// Forward delete intent to the host. The user already chose "delete" in the
    /// row's right-click menu, so no extra confirm dialog.
    private func confirmAndRemove(item: WatchItem) {
        if selectedSymbol == item.normalizedSymbol {
            selectedSymbol = nil
            relocateDetailContainer()
        }
        onRemoveItem?(item.code)
    }

    @objc private func submitAdd() {
        let raw = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        // Accept either 6-digit code, or sh/sz + 6-digit.
        let normalized: String
        if raw.range(of: #"^[a-zA-Z]{2}\d{6}$"#, options: .regularExpression) != nil {
            normalized = String(raw.dropFirst(2))
        } else if raw.range(of: #"^\d{6}$"#, options: .regularExpression) != nil {
            normalized = raw
        } else {
            // invalid input — flash the field
            NSSound.beep()
            codeField.layer?.borderColor = NSColor.systemRed.cgColor
            codeField.layer?.borderWidth = 1
            codeField.wantsLayer = true
            return
        }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        onAddItem?(normalized, alias.isEmpty ? nil : alias)
        // Reset and collapse.
        codeField.stringValue = ""
        aliasField.stringValue = ""
        handleToggleAddBar()
    }

    // MARK: - Header / actions

    @objc private func handleRefresh() { onRefresh?() }
    @objc private func handleOpenConfig() { onOpenConfig?() }
    @objc private func handleOpenPreferences() { onOpenPreferences?() }
    @objc private func handleQuit() { onQuit?() }
    @objc private func handleToggleDesktopCard() { onToggleDesktopCard?() }

    // MARK: - Sort menu

    @objc private func handleSort() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "排序方式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in SortMode.allCases {
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(selectSort(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == SortMode.current) ? .on : .off
            menu.addItem(item)
        }
        let origin = NSPoint(x: 0, y: sortButton.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sortButton)
    }

    @objc private func selectSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SortMode(rawValue: raw),
              mode != SortMode.current
        else { return }
        SortMode.current = mode
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        sortButton.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: "排序")?
            .withSymbolConfiguration(cfg)
        applySortButtonTint()
        reload()
        onSortModeChanged?(mode)
    }

    /// Highlight the sort button when a non-default sort is active, so the user
    /// has a quick visual cue that the list isn't in their manual order.
    private func applySortButtonTint() {
        sortButton.contentTintColor = SortMode.current == .manual
            ? .secondaryLabelColor
            : NSColor.controlAccentColor
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}


/// NSClipView with `isFlipped = true` so the document view's (0, 0) is at the
/// top-left. Without this, NSStackView arranged-subview frames have minY at the
/// bottom of the row, which makes `scrollToVisible` behave unexpectedly.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class WidthResizeHandleView: NSView {
    var currentWidth: (() -> CGFloat)?
    var onWidthChanged: ((CGFloat) -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth?() ?? 520
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartX
        onWidthChanged?(dragStartWidth + dx)
    }
}
