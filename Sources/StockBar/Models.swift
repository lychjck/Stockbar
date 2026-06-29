import Foundation

/// One item in the user's watchlist (one stock or ETF).
struct WatchItem: Codable, Hashable {
    /// Tencent-style symbol with prefix, e.g. "sh000001", "sz159770".
    /// Optional in JSON (legacy) — derived from `code` when missing.
    var symbol: String?
    /// 6-digit code (no prefix), e.g. "000001".
    var code: String
    /// User-defined alias to show in menu, e.g. "卫星".
    var alias: String

    /// Normalized symbol: always with sh/sz prefix.
    var normalizedSymbol: String {
        if let s = symbol?.lowercased(), s.hasPrefix("sh") || s.hasPrefix("sz") {
            return s
        }
        return Self.inferSymbol(from: code)
    }

    /// Heuristic: codes starting with 5/6/9 → SH; otherwise SZ.
    /// Same rule as the existing stockline script.
    static func inferSymbol(from code: String) -> String {
        let first = code.first.map(String.init) ?? ""
        return (["5", "6", "9"].contains(first) ? "sh" : "sz") + code
    }
}

/// Container for watchlist.json on disk.
/// Matches the format used by ~/plugins/stock-statusline/config/watchlist.json
/// so the two tools share one source of truth.
struct Watchlist: Codable {
    var refresh_seconds: Int?
    var max_items: Int?
    var items: [WatchItem]?           // legacy flat layout
    var groups: [String: [WatchItem]]?
    var active_group: String?

    /// Active items: prefer `groups[active_group]`, fall back to `items`.
    var activeItems: [WatchItem] {
        if let groups, let key = active_group, let list = groups[key] {
            return list
        }
        if let groups, let first = groups.first {
            return first.value
        }
        return items ?? []
    }

    var refreshSeconds: TimeInterval {
        TimeInterval(max(1, refresh_seconds ?? 5))
    }

    var maxItems: Int {
        max(1, max_items ?? 4)
    }
}

/// Quote snapshot returned by Tencent's qt.gtimg.cn endpoint.
struct Quote {
    let symbol: String      // e.g. "sh000001"
    let code: String        // e.g. "000001"
    let name: String        // 上证指数 / 卫星ETF永赢 ...
    let price: Double
    let prevClose: Double
    let change: Double
    let pct: Double         // percent, signed
    let high: Double
    let low: Double
    let time: String        // raw "YYYYMMDDHHmmss"

    // Extended fields (may be 0/nil for indices or instruments that don't
    // report them). Parsed relative to the "price/volume/amount" anchor field
    // so they line up across stocks / ETFs / indices alike.
    let open: Double            // 今开
    let volume: Double          // 成交量 (手 / lots)
    let amount: Double          // 成交额 (万元 / 10k CNY)
    let turnoverRate: Double?   // 换手率 % (nil for indices)
    let pe: Double?             // 市盈率 TTM (nil for ETFs / indices)

    var displayName: String { name }

    /// True for broad-market indices (上证指数 sh000xxx, 深证成指/创业板 sz399xxx,
    /// etc.). They don't report a meaningful 换手率 / 市盈率, so callers should
    /// skip those fields rather than show whatever sits in those slots.
    var isIndex: Bool {
        symbol.hasPrefix("sh000") || symbol.hasPrefix("sz399")
    }

    /// 振幅 % = (最高 - 最低) / 昨收 * 100. Computed so it never relies on a
    /// brittle field index.
    var amplitude: Double {
        guard prevClose > 0 else { return 0 }
        return (high - low) / prevClose * 100
    }
}

/// One point on the today-only minute-level chart.
/// Trading hours in CN: 09:30–11:30 and 13:00–15:00 (240 minutes/day).
struct MinutePoint {
    let minutesFromOpen: Int   // 0..239 (09:30 = 0, 11:30 = 119, 13:00 = 120, 15:00 = 239)
    let hhmm: String           // "0930", "1100", "1305" ...
    let price: Double
}
