import AppKit
import StockCore

/// View-only sort applied to the watchlist in the popover and desktop card.
///
/// This is a transient view setting — it does NOT mutate `watchlist.json`.
/// The on-disk order is the "manual" baseline the user can always return to,
/// and `stockline` / drag-reorder keep working as before. Persisted in
/// `UserDefaults` so the chosen sort survives app restarts.
enum SortMode: String, CaseIterable {
    case manual  = "manual"   // user's manual order (from watchlist.json)
    case pctDesc = "pctDesc"  // top movers first
    case pctAsc  = "pctAsc"   // worst movers first

    /// Menu label shown in the header sort button's popup.
    var label: String {
        switch self {
        case .manual:  return "默认顺序"
        case .pctDesc: return "涨幅由高到低"
        case .pctAsc:  return "涨幅由低到高"
        }
    }

    /// SF Symbol shown on the header button to hint the current mode.
    var symbol: String {
        switch self {
        case .manual:  return "arrow.up.arrow.down"
        case .pctDesc: return "arrow.down.to.line"
        case .pctAsc:  return "arrow.up.to.line"
        }
    }

    private static let userDefaultsKey = "StockBar.sortMode"

    /// Currently active sort mode, persisted across launches.
    static var current: SortMode {
        get {
            let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
            return SortMode(rawValue: raw) ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }

    /// Apply this sort to a list of watch items using `quotes` for live data.
    /// Items without a quote are pushed to the bottom in both pct sorts so they
    /// never block live rankings.  Ties (equal pct, or both missing) fall back
    /// to the original input order for stability.
    func apply(to items: [WatchItem], quotes: [String: Quote]) -> [WatchItem] {
        switch self {
        case .manual:
            return items
        case .pctDesc:
            return stableSort(items: items) { a, b in
                let la = quotes[a.normalizedSymbol]?.pct
                let lb = quotes[b.normalizedSymbol]?.pct
                return compareForDescending(la, lb)
            }
        case .pctAsc:
            return stableSort(items: items) { a, b in
                let la = quotes[a.normalizedSymbol]?.pct
                let lb = quotes[b.normalizedSymbol]?.pct
                return compareForAscending(la, lb)
            }
        }
    }

    // MARK: - Comparators

    /// Returns true iff `l` should come before `r` for "biggest first".
    /// nil sorts to the bottom (treated as "less than" any concrete value).
    private func compareForDescending(_ l: Double?, _ r: Double?) -> ComparisonResult {
        switch (l, r) {
        case let (lv?, rv?):
            if lv == rv { return .orderedSame }
            return lv > rv ? .orderedAscending : .orderedDescending
        case (.some, .none): return .orderedAscending     // concrete wins over nil
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }

    /// Returns true iff `l` should come before `r` for "smallest first".
    /// nil sorts to the bottom.
    private func compareForAscending(_ l: Double?, _ r: Double?) -> ComparisonResult {
        switch (l, r) {
        case let (lv?, rv?):
            if lv == rv { return .orderedSame }
            return lv < rv ? .orderedAscending : .orderedDescending
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }

    /// Stable sort: equal-keyed elements keep their original relative order.
    /// Swift's `sorted(by:)` is not guaranteed stable, so we zip with the index
    /// and use it as a tiebreaker.
    private func stableSort(
        items: [WatchItem],
        by compare: (WatchItem, WatchItem) -> ComparisonResult
    ) -> [WatchItem] {
        return items.enumerated()
            .sorted { lhs, rhs in
                switch compare(lhs.element, rhs.element) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:       return lhs.offset < rhs.offset
                }
            }
            .map { $0.element }
    }
}
