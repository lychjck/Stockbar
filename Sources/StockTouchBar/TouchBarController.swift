import AppKit
import StockCore

/// Touch Bar UI orchestrator.
///
/// Design (driven by macOS 26's Control Strip semantics):
///
///   • A single Control Strip widget is the *primary* surface — it stays
///     visible at all times. It renders a compact "headline stock" button
///     (alias + signed pct, in CN red/green). A periodic `stripKeepAlive`
///     timer re-asserts its presence so other apps' strip widgets (Sogou
///     IME's NowPlaying button, etc.) can't quietly bury it.
///   • Tapping the widget pops a modal Touch Bar — an `NSScrubber` of every
///     watchlist item, horizontally scrollable. A custom close button on the
///     right collapses it. The modal itself is *passive*: we don't fight to
///     keep it up across app switches or system minimizes. The user is in
///     charge of when it appears.
///
/// All UI mutations happen on the main actor. `install()` is idempotent;
/// data updates come in via `update(items:quotes:)` on every quote tick.
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate,
                                 NSScrubberDataSource, NSScrubberDelegate,
                                 NSScrubberFlowLayoutDelegate {

    // MARK: - Identifiers

    static let stripIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.controlstrip")
    static let modalRowIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.modal.row")
    static let modalCloseIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.modal.close")
    static let detailBackIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.detail.back")
    static let detailLabelIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.detail.label")
    static let detailChartIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.detail.chart")
    static let detailPinIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.detail.pin")
    static let detailCloseIdentifier =
        NSTouchBarItem.Identifier("local.stocktouchbar.detail.close")
    static let scrubberCellIdentifier =
        NSUserInterfaceItemIdentifier("local.stocktouchbar.scrubber.cell")

    private static let pinnedSymbolKey = "StockTouchBar.pinnedSymbol"

    // MARK: - Strip slot (always-visible single button)

    private let stripItem: NSCustomTouchBarItem
    private let triggerButton: NSButton

    // MARK: - Modal Touch Bar (list view)

    private let modalTouchBar = NSTouchBar()
    private let modalRowItem: NSCustomTouchBarItem
    private let modalCloseItem: NSCustomTouchBarItem
    private let modalCloseButton: NSButton
    private let scrubber: NSScrubber

    // MARK: - Detail Touch Bar (single-stock intraday chart)

    private let detailTouchBar = NSTouchBar()
    private let detailBackItem: NSCustomTouchBarItem
    private let detailBackButton: NSButton
    private let detailLabelItem: NSCustomTouchBarItem
    private let detailLabel: NSTextField
    private let detailChartItem: NSCustomTouchBarItem
    private let detailChartView: TouchBarChartView
    private let detailPinItem: NSCustomTouchBarItem
    private let detailPinButton: NSButton
    private let detailCloseItem: NSCustomTouchBarItem
    private let detailCloseButton: NSButton

    /// Notify AppDelegate that a cell was selected — used to fetch minute
    /// data on demand. Called with the picked `WatchItem`.
    var onSelectDetail: ((WatchItem) -> Void)?

    // MARK: - State

    private var currentItems: [WatchItem] = []
    private var currentQuotes: [String: Quote] = [:]
    /// Cached minute series per normalized symbol. Pushed in by AppDelegate
    /// via `updateMinutes`. Used to populate the chart in the detail view.
    private var currentMinutes: [String: [MinutePoint]] = [:]
    /// Symbol currently shown in the detail Touch Bar, if any. nil means we
    /// are showing the list (or have closed entirely).
    private var detailSymbol: String?
    private var installed = false
    private var modalVisible = false
    private var detailVisible = false

    /// Every 2 s we re-set the strip widget's "presence" in the Control
    /// Strip. macOS 26 lets multiple third-party widgets share the strip
    /// slot, and the most recently re-asserted one wins the visible
    /// position. Without this timer, Sogou IME (which presents its own
    /// Control Strip widget whenever it activates) covers ours indefinitely.
    /// 2 s feels invisible to the user while burning ~no CPU.
    private var stripKeepAliveTimer: Timer?

    // CN convention: up = red, down = green.
    private let upRed     = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.25, alpha: 1.0)
    private let downGreen = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1.0)

    // MARK: - Init

    override init() {
        stripItem = NSCustomTouchBarItem(identifier: Self.stripIdentifier)
        triggerButton = NSButton(title: "—", target: nil, action: nil)
        triggerButton.bezelStyle = .rounded
        triggerButton.isBordered = false
        triggerButton.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        triggerButton.translatesAutoresizingMaskIntoConstraints = false
        stripItem.view = triggerButton

        // ---- Scrubber: horizontally-scrollable strip of stocks.
        scrubber = NSScrubber()
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = 6
        layout.itemSize = NSSize(width: 72, height: 30)
        scrubber.scrubberLayout = layout
        scrubber.mode = .free
        scrubber.selectionBackgroundStyle = nil
        scrubber.selectionOverlayStyle = nil
        scrubber.showsArrowButtons = false
        scrubber.showsAdditionalContentIndicators = true
        scrubber.isContinuous = false
        scrubber.backgroundColor = .clear
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.register(StockScrubberItemView.self,
                          forItemIdentifier: Self.scrubberCellIdentifier)

        modalRowItem = NSCustomTouchBarItem(identifier: Self.modalRowIdentifier)
        modalRowItem.view = scrubber

        // ---- Custom close button on the right of the modal.
        modalCloseButton = NSButton(title: "", target: nil, action: nil)
        modalCloseButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "收起"
        )
        modalCloseButton.imagePosition = .imageOnly
        modalCloseButton.bezelStyle = .rounded
        modalCloseButton.isBordered = false
        modalCloseButton.contentTintColor = .secondaryLabelColor
        modalCloseButton.translatesAutoresizingMaskIntoConstraints = false
        modalCloseItem = NSCustomTouchBarItem(identifier: Self.modalCloseIdentifier)
        modalCloseItem.view = modalCloseButton

        modalTouchBar.defaultItemIdentifiers = [
            Self.modalRowIdentifier,
            Self.modalCloseIdentifier,
        ]

        // ---- Detail Touch Bar items.
        detailBackButton = NSButton(title: "", target: nil, action: nil)
        detailBackButton.image = NSImage(
            systemSymbolName: "chevron.backward.circle.fill",
            accessibilityDescription: "返回列表"
        )
        detailBackButton.imagePosition = .imageOnly
        detailBackButton.bezelStyle = .rounded
        detailBackButton.isBordered = false
        detailBackButton.contentTintColor = .secondaryLabelColor
        detailBackButton.translatesAutoresizingMaskIntoConstraints = false
        detailBackButton.setContentHuggingPriority(.required, for: .horizontal)
        detailBackItem = NSCustomTouchBarItem(identifier: Self.detailBackIdentifier)
        detailBackItem.view = detailBackButton

        detailLabel = NSTextField(labelWithString: "—")
        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        detailLabel.textColor = .labelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailLabelItem = NSCustomTouchBarItem(identifier: Self.detailLabelIdentifier)
        detailLabelItem.view = detailLabel

        detailChartView = TouchBarChartView(frame: NSRect(x: 0, y: 0, width: 720, height: 30))
        detailChartView.upColor = upRed
        detailChartView.downColor = downGreen
        detailChartView.translatesAutoresizingMaskIntoConstraints = false
        // Make chart greedy for horizontal space and let the other items
        // (back / label / close) be sticky, so the chart absorbs all the
        // leftover width in the Touch Bar app region.
        detailChartView.setContentHuggingPriority(.init(50), for: .horizontal)
        detailChartView.setContentCompressionResistancePriority(.init(50), for: .horizontal)
        detailChartItem = NSCustomTouchBarItem(identifier: Self.detailChartIdentifier)
        detailChartItem.view = detailChartView

        detailPinButton = NSButton(title: "", target: nil, action: nil)
        detailPinButton.image = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: "钉住到控制条"
        )
        detailPinButton.imagePosition = .imageOnly
        detailPinButton.bezelStyle = .rounded
        detailPinButton.isBordered = false
        detailPinButton.contentTintColor = .secondaryLabelColor
        detailPinButton.translatesAutoresizingMaskIntoConstraints = false
        detailPinButton.setContentHuggingPriority(.required, for: .horizontal)
        detailPinItem = NSCustomTouchBarItem(identifier: Self.detailPinIdentifier)
        detailPinItem.view = detailPinButton

        detailCloseButton = NSButton(title: "", target: nil, action: nil)
        detailCloseButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "收起"
        )
        detailCloseButton.imagePosition = .imageOnly
        detailCloseButton.bezelStyle = .rounded
        detailCloseButton.isBordered = false
        detailCloseButton.contentTintColor = .secondaryLabelColor
        detailCloseButton.translatesAutoresizingMaskIntoConstraints = false
        detailCloseButton.setContentHuggingPriority(.required, for: .horizontal)
        detailCloseItem = NSCustomTouchBarItem(identifier: Self.detailCloseIdentifier)
        detailCloseItem.view = detailCloseButton

        detailTouchBar.defaultItemIdentifiers = [
            Self.detailBackIdentifier,
            Self.detailLabelIdentifier,
            Self.detailChartIdentifier,
            Self.detailPinIdentifier,
            Self.detailCloseIdentifier,
        ]

        super.init()

        modalTouchBar.delegate = self
        detailTouchBar.delegate = self
        triggerButton.target = self
        triggerButton.action = #selector(handleStripTap(_:))
        modalCloseButton.target = self
        modalCloseButton.action = #selector(handleModalCloseTap(_:))
        detailBackButton.target = self
        detailBackButton.action = #selector(handleDetailBackTap(_:))
        detailPinButton.target = self
        detailPinButton.action = #selector(handleDetailPinTap(_:))
        detailCloseButton.target = self
        detailCloseButton.action = #selector(handleDetailCloseTap(_:))
        scrubber.dataSource = self
        scrubber.delegate = self
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.modalRowIdentifier:    return modalRowItem
        case Self.modalCloseIdentifier:  return modalCloseItem
        case Self.detailBackIdentifier:  return detailBackItem
        case Self.detailLabelIdentifier: return detailLabelItem
        case Self.detailChartIdentifier: return detailChartItem
        case Self.detailPinIdentifier:   return detailPinItem
        case Self.detailCloseIdentifier: return detailCloseItem
        default: return nil
        }
    }

    // MARK: - Install / uninstall

    func install() {
        guard !installed, DFRBridge.isAvailable else { return }
        // Hide the system close-box. Our own close button on the right of
        // the modal handles user-triggered collapse, and we never want the
        // system one randomly showing up (its callback isn't observable).
        DFRBridge.setSystemModalShowsCloseBoxWhenFrontMost(false)
        DFRBridge.addSystemTrayItem(stripItem)
        DFRBridge.setControlStripPresence(identifier: Self.stripIdentifier, present: true)
        installed = true
        // Start asserting strip widget presence so other apps can't bury it.
        startStripKeepAlive()
    }

    func uninstall() {
        guard installed else { return }
        stopStripKeepAlive()
        if detailVisible {
            DFRBridge.dismissSystemModalTouchBar(detailTouchBar)
            detailVisible = false
        }
        if modalVisible {
            DFRBridge.dismissSystemModalTouchBar(modalTouchBar)
            modalVisible = false
        }
        DFRBridge.setControlStripPresence(identifier: Self.stripIdentifier, present: false)
        DFRBridge.removeSystemTrayItem(stripItem)
        installed = false
    }

    // MARK: - Strip widget keep-alive

    /// Start the loop that re-asserts our Control Strip widget every 2 s,
    /// countering other apps' widgets that may try to cover ours.
    private func startStripKeepAlive() {
        stripKeepAliveTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.installed else { return }
                DFRBridge.setControlStripPresence(
                    identifier: Self.stripIdentifier,
                    present: true
                )
            }
        }
        RunLoop.main.add(t, forMode: .common)
        stripKeepAliveTimer = t
    }

    private func stopStripKeepAlive() {
        stripKeepAliveTimer?.invalidate()
        stripKeepAliveTimer = nil
    }

    // MARK: - Data binding

    func update(items: [WatchItem], quotes: [String: Quote]) {
        currentItems = items
        currentQuotes = quotes
        rebuildTrigger()
        scrubber.reloadData()
        // If the detail bar is up, also refresh its labels/colors against
        // the freshest quote.
        if let sym = detailSymbol {
            refreshDetail(for: sym)
        }
    }

    /// Push a freshly-fetched minute series in. AppDelegate calls this on
    /// every minute-tick or after an on-demand fetch.
    func updateMinutes(symbol: String, points: [MinutePoint]) {
        currentMinutes[symbol] = points
        if detailSymbol == symbol {
            detailChartView.points = points
        }
    }

    // MARK: - Strip widget content (headline stock)

    private func rebuildTrigger() {
        let headline = pickHeadlineItem()
        guard let headline else {
            triggerButton.attributedTitle = NSAttributedString(string: "—")
            return
        }
        let sym = headline.normalizedSymbol
        let q = currentQuotes[sym]
        let pctText = pctString(q?.pct)
        let color = pctColor(q?.pct)
        // Control Strip widgets only get ~55pt of room — about enough for
        // a 7-char monospaced string like "+12.34%". Trying to fit "alias
        // +12.34%" gets truncated mid-character. We rely on red/green to
        // imply direction, and let the user tap the widget to see the full
        // list (including the headline's alias) in the modal.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ]
        triggerButton.attributedTitle = NSAttributedString(
            string: pctText,
            attributes: attrs
        )
        triggerButton.contentTintColor = color
        // Surface which stock the strip widget is tracking via the tooltip,
        // since we can't fit the alias on the widget itself.
        let alias = headline.alias.isEmpty ? (q?.name ?? headline.code) : headline.alias
        triggerButton.toolTip = "\(alias)  \(pctText)"
    }

    /// Pick the stock displayed on the Control Strip button. Preference order:
    ///   1. UserDefaults pinned symbol (if it's still in the watchlist).
    ///   2. First watchlist item.
    ///   3. nil → render placeholder.
    private func pickHeadlineItem() -> WatchItem? {
        if let pinned = UserDefaults.standard.string(forKey: Self.pinnedSymbolKey),
           let match = currentItems.first(where: { $0.normalizedSymbol == pinned }) {
            return match
        }
        return currentItems.first
    }

    // MARK: - Modal lifecycle (simple toggle)

    @objc private func handleStripTap(_ sender: Any?) {
        // Unconditionally re-present. Repeat-presenting the same touchBar is
        // idempotent at the system level, so this works whether the modal is
        // already visible (no-op) or was minimized by the system's left-side
        // close-box (which we can't observe and which keeps `modalVisible`
        // stuck at true). Without this, tapping the strip widget after the
        // system close-box silently does nothing.
        scrubber.reloadData()
        DFRBridge.presentSystemModalTouchBar(
            modalTouchBar,
            systemTrayItemIdentifier: Self.stripIdentifier
        )
        modalVisible = true
    }

    @objc private func handleModalCloseTap(_ sender: Any?) {
        DFRBridge.dismissSystemModalTouchBar(modalTouchBar)
        modalVisible = false
    }

    // MARK: - Detail Touch Bar lifecycle

    /// Switch from the list modal to the detail modal for the given symbol.
    /// Triggered by NSScrubber selection; also re-callable to update.
    private func showDetail(for symbol: String) {
        guard let item = currentItems.first(where: { $0.normalizedSymbol == symbol }) else { return }
        detailSymbol = symbol
        refreshDetail(for: symbol)
        // Ask AppDelegate to populate / refresh the minute series.
        onSelectDetail?(item)
        // Tear down the list modal first so the system doesn't try to host
        // both simultaneously.
        if modalVisible {
            DFRBridge.dismissSystemModalTouchBar(modalTouchBar)
            modalVisible = false
        }
        DFRBridge.presentSystemModalTouchBar(
            detailTouchBar,
            systemTrayItemIdentifier: Self.stripIdentifier
        )
        detailVisible = true
    }

    /// Update label + chart with the freshest data for the currently
    /// displayed symbol. Called both on initial show and on every quote
    /// tick (in `update(items:quotes:)`) so price/pct stays live.
    private func refreshDetail(for symbol: String) {
        guard let item = currentItems.first(where: { $0.normalizedSymbol == symbol }) else { return }
        let q = currentQuotes[symbol]
        let alias = item.alias.isEmpty ? (q?.name ?? item.code) : item.alias
        let pct = pctString(q?.pct)
        let priceStr = q.map { String(format: "%.3f", $0.price) } ?? "—"
        let color = pctColor(q?.pct)

        // Compose "alias  price  +1.23%" — alias gray, price/pct colored.
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: alias + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        attr.append(NSAttributedString(string: priceStr + "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ]))
        attr.append(NSAttributedString(string: pct, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ]))
        detailLabel.attributedStringValue = attr

        detailChartView.quote = q
        detailChartView.points = currentMinutes[symbol] ?? []

        // Reflect pin state on the button: filled pin if this symbol is the
        // current Control Strip headline, hollow pin otherwise.
        let pinned = UserDefaults.standard.string(forKey: Self.pinnedSymbolKey)
        let isPinned = (pinned == symbol)
        detailPinButton.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: isPinned ? "取消钉住" : "钉住到控制条"
        )
        detailPinButton.contentTintColor = isPinned ? upRed : .secondaryLabelColor
    }

    @objc private func handleDetailBackTap(_ sender: Any?) {
        detailSymbol = nil
        DFRBridge.dismissSystemModalTouchBar(detailTouchBar)
        detailVisible = false
        // Reload + re-present the list modal.
        scrubber.reloadData()
        DFRBridge.presentSystemModalTouchBar(
            modalTouchBar,
            systemTrayItemIdentifier: Self.stripIdentifier
        )
        modalVisible = true
    }

    /// Toggle "pin to Control Strip" for the currently shown symbol.
    /// Pinned stock is what the strip widget displays. Tapping pin again
    /// (or pinning another stock) clears the previous one — only one
    /// stock can be pinned at a time. Falling back to "no pin" reverts
    /// the strip widget to the first watchlist item.
    @objc private func handleDetailPinTap(_ sender: Any?) {
        guard let sym = detailSymbol else { return }
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: Self.pinnedSymbolKey)
        if current == sym {
            defaults.removeObject(forKey: Self.pinnedSymbolKey)
        } else {
            defaults.set(sym, forKey: Self.pinnedSymbolKey)
        }
        // Refresh both surfaces so the change is immediate:
        //   - the pin button on the detail bar flips fill/hollow
        //   - the strip widget switches to / away from this symbol
        refreshDetail(for: sym)
        rebuildTrigger()
    }

    @objc private func handleDetailCloseTap(_ sender: Any?) {
        detailSymbol = nil
        DFRBridge.dismissSystemModalTouchBar(detailTouchBar)
        detailVisible = false
    }

    // MARK: - NSScrubberDataSource

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        currentItems.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let cell = scrubber.makeItem(
            withIdentifier: Self.scrubberCellIdentifier,
            owner: nil
        ) as? StockScrubberItemView ?? StockScrubberItemView(frame: .zero)
        let item = currentItems[index]
        cell.configure(
            item: item,
            quote: currentQuotes[item.normalizedSymbol],
            upColor: upRed,
            downColor: downGreen
        )
        return cell
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard index >= 0, index < currentItems.count else { return }
        let item = currentItems[index]
        showDetail(for: item.normalizedSymbol)
    }

    // MARK: - NSScrubberFlowLayoutDelegate

    func scrubber(_ scrubber: NSScrubber,
                  layout: NSScrubberFlowLayout,
                  sizeForItemAt itemIndex: Int) -> NSSize {
        guard itemIndex < currentItems.count else {
            return NSSize(width: 72, height: 30)
        }
        let item = currentItems[itemIndex]
        let sym = item.normalizedSymbol
        let quote = currentQuotes[sym]
        let alias = item.alias.isEmpty ? (quote?.name ?? item.code) : item.alias
        let pct = pctString(quote?.pct)

        let aliasWidth = StockScrubberItemView.width(
            of: alias,
            font: StockScrubberItemView.nameFont
        )
        let pctWidth = StockScrubberItemView.width(
            of: pct,
            font: StockScrubberItemView.pctFont
        )
        let inner = max(aliasWidth, pctWidth)
        let padded = ceil(inner) + 16
        return NSSize(width: max(56, min(120, padded)), height: 30)
    }

    // MARK: - Formatters

    private func pctString(_ pct: Double?) -> String {
        guard let pct else { return "—" }
        let sign = pct > 0 ? "+" : ""
        return sign + String(format: "%.2f%%", pct)
    }

    private func pctColor(_ pct: Double?) -> NSColor {
        guard let pct, pct != 0 else { return .labelColor }
        return pct > 0 ? upRed : downGreen
    }
}

// MARK: - Scrubber cell view

/// Two-line scrubber cell: alias on top, signed % on bottom. Reused via the
/// scrubber's recycling pool, so `configure(...)` may be called many times on
/// the same instance.
final class StockScrubberItemView: NSScrubberItemView {

    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let pctFont  = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)

    private let nameLabel = NSTextField(labelWithString: "")
    private let pctLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        pctLabel.font = Self.pctFont
        pctLabel.alignment = .center
        pctLabel.lineBreakMode = .byClipping
        pctLabel.maximumNumberOfLines = 1
        pctLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [nameLabel, pctLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    func configure(item: WatchItem, quote: Quote?, upColor: NSColor, downColor: NSColor) {
        let alias = item.alias.isEmpty ? (quote?.name ?? item.code) : item.alias
        nameLabel.stringValue = alias

        if let pct = quote?.pct {
            let sign = pct > 0 ? "+" : ""
            pctLabel.stringValue = sign + String(format: "%.2f%%", pct)
            if pct > 0 { pctLabel.textColor = upColor }
            else if pct < 0 { pctLabel.textColor = downColor }
            else { pctLabel.textColor = .labelColor }
        } else {
            pctLabel.stringValue = "—"
            pctLabel.textColor = .secondaryLabelColor
        }
    }

    static func width(of string: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (string as NSString).size(withAttributes: attrs).width
    }
}
