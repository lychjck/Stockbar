import Foundation

/// Loads and saves the watchlist config.
/// Default path: shared with stock-statusline plugin so users only manage one file.
public final class WatchlistStore {
    public static let defaultConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("plugins/stock-statusline/config/watchlist.json")
            .path
    }()

    /// Fallback path if the shared config doesn't exist — keep StockBar self-contained.
    public static let fallbackConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/stockbar/watchlist.json")
            .path
    }()

    public let configPath: String

    public init(configPath: String? = nil) {
        if let configPath {
            self.configPath = configPath
        } else if FileManager.default.fileExists(atPath: WatchlistStore.defaultConfigPath) {
            self.configPath = WatchlistStore.defaultConfigPath
        } else {
            self.configPath = WatchlistStore.fallbackConfigPath
        }
    }

    /// Load watchlist from disk. Returns an empty list if file is missing/corrupt.
    public func load() -> Watchlist {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return Watchlist()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Watchlist.self, from: data)) ?? Watchlist()
    }

    /// Append (or update) one item in the active group, then persist.
    /// Returns the saved Watchlist (with the new item visible) so the caller can
    /// refresh UI without waiting for the file-system watcher to fire.
    @discardableResult
    public func addItem(code: String, alias: String?) throws -> Watchlist {
        var current = load()
        let activeKey = current.active_group ?? "default"
        var groups = current.groups ?? [:]
        var list = groups[activeKey] ?? current.items ?? []

        let symbol = WatchItem.inferSymbol(from: code)
        // De-duplicate on normalized symbol; if the code already exists, just update alias.
        if let idx = list.firstIndex(where: { $0.normalizedSymbol == symbol }) {
            if let alias, !alias.isEmpty {
                list[idx].alias = alias
            }
        } else {
            list.append(WatchItem(symbol: symbol, code: code, alias: alias ?? ""))
        }

        groups[activeKey] = list
        current.groups = groups
        current.active_group = activeKey
        // Mirror to legacy `items` so older readers still see the change.
        current.items = list

        try save(current)
        return current
    }

    /// Remove one item by 6-digit code from the active group.
    @discardableResult
    public func removeItem(code: String) throws -> Watchlist {
        var current = load()
        let activeKey = current.active_group ?? "default"
        var groups = current.groups ?? [:]
        var list = groups[activeKey] ?? current.items ?? []

        let symbol = WatchItem.inferSymbol(from: code)
        list.removeAll { $0.normalizedSymbol == symbol }

        groups[activeKey] = list
        current.groups = groups
        current.active_group = activeKey
        current.items = list
        try save(current)
        return current
    }

    /// Persist the watchlist as pretty-printed JSON.
    public func save(_ list: Watchlist) throws {
        // Ensure parent directory exists.
        let url = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(list)
        try data.write(to: url, options: .atomic)
    }

    /// Reorder the active group to match the given normalized-symbol order.
    /// Items not in the order list keep their relative positions at the end.
    @discardableResult
    public func reorder(symbolsInOrder: [String]) throws -> Watchlist {
        var current = load()
        let activeKey = current.active_group ?? "default"
        var groups = current.groups ?? [:]
        let list = groups[activeKey] ?? current.items ?? []

        // Index existing items by normalized symbol.
        var bySymbol: [String: WatchItem] = [:]
        for item in list { bySymbol[item.normalizedSymbol] = item }

        var reordered: [WatchItem] = []
        var seen = Set<String>()
        for sym in symbolsInOrder {
            if let item = bySymbol[sym] {
                reordered.append(item)
                seen.insert(sym)
            }
        }
        // Append any items that weren't mentioned (shouldn't happen, but be safe).
        for item in list where !seen.contains(item.normalizedSymbol) {
            reordered.append(item)
        }

        groups[activeKey] = reordered
        current.groups = groups
        current.active_group = activeKey
        current.items = reordered
        try save(current)
        return current
    }

    /// Watch the config file for external edits (e.g. `stockline add ...`).
    /// Calls `onChange` on the main queue when the file is rewritten.
    /// Returns a DispatchSourceFileSystemObject that the caller must retain.
    public func watchForChanges(_ onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let targetURL = URL(fileURLWithPath: configPath)
        let watchPath: String
        if FileManager.default.fileExists(atPath: configPath) {
            watchPath = configPath
        } else {
            let parent = targetURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            watchPath = parent.path
        }

        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            onChange()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }
}
