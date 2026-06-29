import AppKit
import Foundation
import Carbon.HIToolbox

@main
final class StockBarApp {
    static func main() {
        let app = NSApplication.shared
        // Background-only agent: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // Status bar
    private var statusItem: NSStatusItem!

    // Popover
    private let popover = NSPopover()
    private let popoverController = PopoverController()

    // Desktop floating card widget
    private let desktopCard = DesktopCardController()
    private var toggleHotKey: GlobalHotKey?

    // Data layer
    private let store = WatchlistStore()
    private let quoteFetcher = QuoteFetcher()
    private let minuteFetcher = MinuteFetcher()

    private var watchlist = Watchlist()
    private var quotes: [String: Quote] = [:]
    private var minutes: [String: [MinutePoint]] = [:]
    private var lastFetchedAt: Date?

    // Timers
    private var quoteTimer: Timer?
    private var minuteTimer: Timer?
    private var fileWatcher: DispatchSourceFileSystemObject?

    // Status-bar display preference.
    // mode: "icon" (just the SF Symbol) or "symbol" (a pinned watch item's
    // alias + percent change rendered as text). `statusSymbol` holds the
    // pinned item's normalized symbol. Stored in UserDefaults (not the shared
    // watchlist.json) so we never pollute the file shared with `stockline`.
    private let statusModeKey = "StatusBar.mode"
    private let statusSymbolKey = "StatusBar.symbol"

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchlist = store.load()

        // ---- Status item: icon or a pinned symbol's text, no fixed width.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Catch right-click separately if needed; left-click toggles popover.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItemDisplay()

        // ---- Popover
        popover.contentViewController = popoverController
        popover.behavior = .transient            // auto-close on outside click
        popover.animates = true
        popover.delegate = self
        popoverController.popover = popover     // so the controller can resize it

        popoverController.onRefresh = { [weak self] in
            Task { await self?.refreshAll(force: true) }
        }
        popoverController.onOpenConfig = { [weak self] in
            self?.openConfigFile()
        }
        popoverController.onQuit = {
            NSApp.terminate(nil)
        }
        popoverController.onSelectionChanged = { [weak self] item in
            guard let self else { return }
            if let item {
                Task { await self.fetchMinutes(for: item.normalizedSymbol, alsoMissing: false) }
            }
        }
        popoverController.onAddItem = { [weak self] code, alias in
            self?.handleAddItem(code: code, alias: alias)
        }
        popoverController.onRemoveItem = { [weak self] code in
            self?.handleRemoveItem(code: code)
        }
        popoverController.onReorder = { [weak self] order in
            self?.handleReorder(order: order)
        }

        // Desktop card: toggle from the popover header; clicking its own close
        // button just hides it (no extra state to sync since the button is
        // stateless).
        popoverController.onToggleDesktopCard = { [weak self] in
            self?.toggleDesktopCard()
        }

        // When a row in the desktop card is tapped, pull that symbol's minute
        // series so the expanded chart is fresh.
        desktopCard.onSelectRow = { [weak self] item in
            guard let self, let item else { return }
            Task { await self.fetchMinutes(for: item.normalizedSymbol, alsoMissing: false) }
        }

        // System-wide hot key (⌥⌘S) to show/hide the desktop card from anywhere.
        // Carbon hot keys need no Accessibility permission and work in the
        // background. If the combo is already taken, registration silently fails.
        toggleHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in self?.toggleDesktopCard() }
        }

        startQuoteTimer()
        startMinuteTimer()
        startWatchingConfigFile()

        Task {
            await self.refreshAll(force: true)
            // Restore the desktop card from last session *after* the first data
            // load so it shows live numbers immediately.
            self.desktopCard.restoreIfNeeded()
            if self.desktopCard.isVisible {
                await self.fetchAllMinutesIfNeeded()
                self.pushDataToCard()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        quoteTimer?.invalidate()
        minuteTimer?.invalidate()
        fileWatcher?.cancel()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        // buttonNumber 1 = right-click; anything else = left-click.
        if NSApp.currentEvent?.buttonNumber == 1 {
            showStatusMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Push freshest data into the controller before showing.
            pushDataToController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Activate so the popover can receive keyboard events.
            NSApp.activate(ignoringOtherApps: true)
            // Pull minute data for everything not yet cached today.
            Task { await self.fetchAllMinutesIfNeeded() }
            // And refresh the quotes too.
            Task { await self.refreshQuotes(force: true) }
        }
    }

    func popoverWillShow(_ notification: Notification) {
        pushDataToController()
    }

    private func pushDataToController() {
        popoverController.items = watchlist.activeItems
        popoverController.quotes = quotes
        popoverController.minutes = minutes
        popoverController.lastUpdated = lastFetchedAt
        popoverController.marketPhase = MarketHours.currentPhase()
        popoverController.reload()
    }

    /// Mirror current data into the desktop card. The card ignores the call
    /// while hidden, so this is safe to invoke unconditionally.
    private func pushDataToCard() {
        desktopCard.items = watchlist.activeItems
        desktopCard.quotes = quotes
        desktopCard.minutes = minutes
        desktopCard.lastUpdated = lastFetchedAt
        desktopCard.marketPhase = MarketHours.currentPhase()
        desktopCard.reload()
    }

    /// Show/hide the desktop card. Triggered by the popover button and the
    /// global hot key. When showing, push fresh data and pull minute series.
    private func toggleDesktopCard() {
        desktopCard.toggle()
        if desktopCard.isVisible {
            pushDataToCard()
            Task { await self.fetchAllMinutesIfNeeded() }
        }
    }

    // MARK: - Refresh loops

    private func startQuoteTimer() {
        quoteTimer?.invalidate()
        let base = watchlist.refreshSeconds
        let interval = MarketHours.recommendedInterval(base: base)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshQuotes(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        quoteTimer = timer
    }

    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        // Minute data updates once per minute on the source side, so polling at 30s is plenty.
        // Outside trading hours we don't poll at all.
        let interval: TimeInterval = MarketHours.currentPhase().isLive ? 30 : 0
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchAllMinutesIfNeeded(forceAll: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func startWatchingConfigFile() {
        fileWatcher?.cancel()
        fileWatcher = store.watchForChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchlist = self.store.load()
                self.startQuoteTimer()
                await self.refreshAll(force: true)
            }
        }
    }

    /// Re-fetch quotes (and minutes if popover open).
    private func refreshAll(force: Bool) async {
        await refreshQuotes(force: force)
        if popover.isShown {
            await fetchAllMinutesIfNeeded(forceAll: force)
        }
    }

    private func refreshQuotes(force: Bool) async {
        let items = watchlist.activeItems
        guard !items.isEmpty else {
            self.quotes = [:]
            self.lastFetchedAt = Date()
            pushDataToController()
            pushDataToCard()
            return
        }
        let symbols = items.map { $0.normalizedSymbol }
        do {
            let result = try await quoteFetcher.fetch(symbols: symbols)
            for q in result { self.quotes[q.symbol] = q }
            self.lastFetchedAt = Date()
            // Adjust timer if we just crossed a phase boundary.
            startQuoteTimer()
            startMinuteTimer()
            // If popover is showing, push update.
            if popover.isShown {
                pushDataToController()
            }
            pushDataToCard()
            updateStatusItemDisplay()
        } catch {
            // Keep stale quotes; mark in tooltip.
            statusItem.button?.toolTip = "Last fetch failed: \(error)"
        }
    }

    /// Fetch minute data for one symbol; updates cache and pushes to controller.
    private func fetchMinutes(for symbol: String, alsoMissing: Bool) async {
        do {
            let pts = try await minuteFetcher.fetch(symbol: symbol)
            self.minutes[symbol] = pts
            if popover.isShown { pushDataToController() }
            pushDataToCard()
        } catch {
            // ignore — chart will show "no data"
        }
    }

    /// Fetch minutes for every watch item.
    /// - Parameter forceAll: if false, only fetches symbols whose cache is empty.
    private func fetchAllMinutesIfNeeded(forceAll: Bool = false) async {
        let symbols = watchlist.activeItems.map { $0.normalizedSymbol }
        await withTaskGroup(of: (String, [MinutePoint]?).self) { group in
            for s in symbols {
                if !forceAll, let cached = minutes[s], !cached.isEmpty { continue }
                group.addTask { [minuteFetcher] in
                    do { return (s, try await minuteFetcher.fetch(symbol: s)) }
                    catch { return (s, nil) }
                }
            }
            for await (sym, pts) in group {
                if let pts { self.minutes[sym] = pts }
            }
        }
        if popover.isShown { pushDataToController() }
        pushDataToCard()
    }

    // MARK: - Add / remove

    private func handleAddItem(code: String, alias: String?) {
        do {
            let updated = try store.addItem(code: code, alias: alias)
            self.watchlist = updated
            // Push immediately so the new row shows up before the file watcher fires.
            pushDataToController()
            pushDataToCard()
            Task { await self.refreshAll(force: true) }
        } catch {
            statusItem.button?.toolTip = "Failed to add: \(error)"
        }
    }

    private func handleRemoveItem(code: String) {
        do {
            let updated = try store.removeItem(code: code)
            self.watchlist = updated
            // Drop cached quotes/minutes for the removed symbol so we don't keep
            // stale data around.
            let sym = WatchItem.inferSymbol(from: code)
            quotes.removeValue(forKey: sym)
            minutes.removeValue(forKey: sym)
            pushDataToController()
            pushDataToCard()
            updateStatusItemDisplay()
        } catch {
            statusItem.button?.toolTip = "Failed to remove: \(error)"
        }
    }

    private func handleReorder(order: [String]) {
        do {
            let updated = try store.reorder(symbolsInOrder: order)
            self.watchlist = updated
            // Don't push immediately — the rows are already in the right order
            // visually; pushing here would rebuild and disturb the user. The
            // file-system watcher will fire and reconcile state shortly.
        } catch {
            statusItem.button?.toolTip = "Failed to reorder: \(error)"
        }
    }

    // MARK: - Status-bar display (icon vs pinned symbol)

    private let upRed = NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.20, alpha: 1.0)
    private let downGreen = NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.30, alpha: 1.0)

    /// Render the status-bar button per the saved preference: either the SF
    /// Symbol icon, or a pinned watch item's "alias +1.23%" text (red up /
    /// green down, CN convention). Falls back to the icon if the pinned symbol
    /// is missing or has no quote yet.
    private func updateStatusItemDisplay() {
        guard let button = statusItem.button else { return }
        let mode = UserDefaults.standard.string(forKey: statusModeKey) ?? "icon"
        let pinned = UserDefaults.standard.string(forKey: statusSymbolKey)

        if mode == "symbol",
           let sym = pinned,
           let item = watchlist.activeItems.first(where: { $0.normalizedSymbol == sym }) {
            let label = item.alias.isEmpty ? (quotes[sym]?.name ?? item.code) : item.alias
            if let q = quotes[sym] {
                let pctStr = (q.pct >= 0 ? "+" : "") + String(format: "%.2f%%", q.pct)
                let color: NSColor = q.pct > 0 ? upRed : (q.pct < 0 ? downGreen : .labelColor)
                button.image = nil
                button.attributedTitle = NSAttributedString(
                    string: "\(label) \(pctStr)",
                    attributes: [
                        .foregroundColor: color,
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    ]
                )
            } else {
                // No quote yet — show the bare label so the user still sees their pick.
                button.image = nil
                button.title = label
            }
            return
        }

        // Default: icon only.
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        let icon = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                           accessibilityDescription: "StockBar")
        icon?.isTemplate = true
        button.image = icon
    }

    /// Pop up the right-click configuration menu under the status item.
    private func showStatusMenu() {
        let menu = buildStatusMenu()
        guard let button = statusItem.button else { return }
        let origin = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: button)
    }

    /// Build the "菜单栏显示" menu: an icon-only option plus one row per watch
    /// item, with a checkmark on the current selection.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let mode = UserDefaults.standard.string(forKey: statusModeKey) ?? "icon"
        let pinned = UserDefaults.standard.string(forKey: statusSymbolKey)

        let header = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let iconItem = NSMenuItem(title: "仅显示图标",
                                  action: #selector(selectStatusIcon),
                                  keyEquivalent: "")
        iconItem.target = self
        iconItem.state = (mode == "icon") ? .on : .off
        menu.addItem(iconItem)

        menu.addItem(.separator())

        for item in watchlist.activeItems {
            let sym = item.normalizedSymbol
            let label = item.alias.isEmpty ? (quotes[sym]?.name ?? item.code) : item.alias
            let mi = NSMenuItem(title: "\(label)  \(item.code)",
                                action: #selector(selectStatusSymbol(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = sym
            mi.state = (mode == "symbol" && pinned == sym) ? .on : .off
            menu.addItem(mi)
        }

        return menu
    }

    @objc private func selectStatusIcon() {
        UserDefaults.standard.set("icon", forKey: statusModeKey)
        updateStatusItemDisplay()
    }

    @objc private func selectStatusSymbol(_ sender: NSMenuItem) {
        guard let sym = sender.representedObject as? String else { return }
        UserDefaults.standard.set("symbol", forKey: statusModeKey)
        UserDefaults.standard.set(sym, forKey: statusSymbolKey)
        updateStatusItemDisplay()
    }

    // MARK: - Open config file

    private func openConfigFile() {
        let path = store.configPath
        if !FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(
                atPath: path,
                contents: Data("{\n  \"refresh_seconds\": 5,\n  \"max_items\": 4,\n  \"items\": []\n}\n".utf8)
            )
        }
        // Bypass the .json file association (which may be stolen by WeChat
        // mini-program devtools, etc.) and force the system's default *text* editor.
        // `open -t` honours the Public.plain-text type association, falling back
        // to TextEdit on a clean system.
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-t", path]
        do {
            try task.run()
        } catch {
            // If `open -t` fails for any reason, fall back to default behavior.
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
