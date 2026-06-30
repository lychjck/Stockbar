import AppKit
import Foundation
import StockCore

/// Drives the Touch Bar app: loads the watchlist, polls quotes on a market-
/// aware schedule, and pushes each tick into `TouchBarController`.
///
/// LSUIElement agent process — no Dock icon, no window. The only UI surface
/// is the Control Strip item the controller installs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = WatchlistStore()
    private let quoteFetcher = QuoteFetcher()
    private let touchBarController = TouchBarController()

    private var watchlist = Watchlist()
    private var quotes: [String: Quote] = [:]

    private var refreshTimer: Timer?
    private var fileWatcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !DFRBridge.isAvailable {
            NSLog("[StockTouchBar] DFRFoundation 不可用，机器似乎没有 Touch Bar — agent 继续运行但不会显示内容。")
        }

        watchlist = store.load()

        touchBarController.install()
        pushDataToController()  // show "—" placeholder immediately

        startRefreshTimer()
        startWatchingConfigFile()

        Task { await refreshQuotes() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        fileWatcher?.cancel()
        touchBarController.uninstall()
    }

    // MARK: - Refresh loop

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = MarketHours.recommendedInterval(base: watchlist.refreshSeconds)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshQuotes() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func startWatchingConfigFile() {
        fileWatcher?.cancel()
        fileWatcher = store.watchForChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchlist = self.store.load()
                self.startRefreshTimer()
                await self.refreshQuotes()
            }
        }
    }

    private func refreshQuotes() async {
        let items = watchlist.activeItems
        guard !items.isEmpty else {
            quotes = [:]
            pushDataToController()
            return
        }
        let symbols = items.map { $0.normalizedSymbol }
        do {
            let result = try await quoteFetcher.fetch(symbols: symbols)
            for q in result { quotes[q.symbol] = q }
            pushDataToController()
            // Phase boundaries change cadence; re-sync the timer just in case.
            startRefreshTimer()
        } catch {
            NSLog("[StockTouchBar] fetch failed: \(error)")
        }
    }

    private func pushDataToController() {
        touchBarController.update(items: watchlist.activeItems, quotes: quotes)
    }
}
