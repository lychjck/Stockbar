import AppKit
import Foundation
import StockCore

/// Drives the Touch Bar app: loads the watchlist, polls quotes on a market-
/// aware schedule, fetches today's minute series on-demand for the detail
/// chart, and pushes each tick into `TouchBarController`.
///
/// LSUIElement agent process — no Dock icon, no window. The only UI surface
/// is the Control Strip item the controller installs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = WatchlistStore()
    private let quoteFetcher = QuoteFetcher()
    private let minuteFetcher = MinuteFetcher()
    private let touchBarController = TouchBarController()

    private var watchlist = Watchlist()
    private var quotes: [String: Quote] = [:]
    /// Minute series cache keyed by normalized symbol (e.g. "sh000001").
    /// Populated lazily when the user opens the detail Touch Bar for a stock.
    private var minutes: [String: [MinutePoint]] = [:]

    private var refreshTimer: Timer?
    private var minuteTimer: Timer?
    private var fileWatcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !DFRBridge.isAvailable {
            NSLog("[StockTouchBar] DFRFoundation 不可用，机器似乎没有 Touch Bar — agent 继续运行但不会显示内容。")
        }

        watchlist = store.load()

        touchBarController.install()
        pushDataToController()  // show "—" placeholder immediately

        // Detail-view selection: user tapped a scrubber cell. Fetch the
        // minute series if we don't have it yet; the controller already
        // populated the chart from whatever cache it had at that moment.
        touchBarController.onSelectDetail = { [weak self] item in
            guard let self else { return }
            Task { @MainActor in
                await self.fetchMinutes(for: item.normalizedSymbol, force: false)
            }
        }

        startRefreshTimer()
        startMinuteTimer()
        startWatchingConfigFile()

        Task { await refreshQuotes() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        minuteTimer?.invalidate()
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

    /// Minute data updates ~once a minute on the server side. We poll 30s
    /// during live sessions and pause completely outside trading hours.
    /// Only refreshes symbols whose minute series we already cached (i.e.
    /// stocks the user has previously opened the detail bar for).
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        let interval: TimeInterval = MarketHours.currentPhase().isLive ? 30 : 0
        guard interval > 0 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshCachedMinutes() }
        }
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
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
            // Phase boundaries change cadence; re-sync the timers in case
            // we just crossed one (e.g. into lunch break or close).
            startRefreshTimer()
            startMinuteTimer()
        } catch {
            NSLog("[StockTouchBar] fetch failed: \(error)")
        }
    }

    /// Fetch (or re-fetch) minute series for one symbol and forward it to
    /// the controller. Called from `onSelectDetail` (on tap) and from the
    /// minute polling loop (for cached symbols).
    private func fetchMinutes(for symbol: String, force: Bool) async {
        if !force, minutes[symbol] != nil {
            // Still push: the controller may have just opened the detail
            // view and needs whatever we already had.
            touchBarController.updateMinutes(symbol: symbol, points: minutes[symbol] ?? [])
            return
        }
        do {
            let pts = try await minuteFetcher.fetch(symbol: symbol)
            minutes[symbol] = pts
            touchBarController.updateMinutes(symbol: symbol, points: pts)
        } catch {
            NSLog("[StockTouchBar] minute fetch failed for \(symbol): \(error)")
        }
    }

    /// Refresh minute series only for symbols we've already cached (i.e. the
    /// user has previously opened them). Avoids hammering the endpoint for
    /// every watchlist item during the entire trading day.
    private func refreshCachedMinutes() async {
        let cached = Array(minutes.keys)
        await withTaskGroup(of: (String, [MinutePoint]?).self) { group in
            for s in cached {
                group.addTask { [minuteFetcher] in
                    do { return (s, try await minuteFetcher.fetch(symbol: s)) }
                    catch { return (s, nil) }
                }
            }
            for await (sym, pts) in group {
                if let pts {
                    minutes[sym] = pts
                    touchBarController.updateMinutes(symbol: sym, points: pts)
                }
            }
        }
    }

    private func pushDataToController() {
        touchBarController.update(items: watchlist.activeItems, quotes: quotes)
    }
}
