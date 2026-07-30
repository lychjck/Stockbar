import Foundation

/// One item in the user's watchlist (one stock or ETF).
public struct WatchItem: Codable, Hashable {
    /// Tencent-style symbol with prefix, e.g. "sh000001", "sz159770".
    /// Optional in JSON (legacy) — derived from `code` when missing.
    public var symbol: String?
    /// 6-digit code (no prefix), e.g. "000001".
    public var code: String
    /// User-defined alias to show in menu, e.g. "卫星".
    public var alias: String
    /// Position info from tzzb (optional) — cost price.
    public var cost: Double?
    /// Position info from tzzb (optional) — shares held.
    public var shares: Double?
    /// Position info from tzzb (optional) — account name.
    public var account: String?

    public init(symbol: String? = nil, code: String, alias: String, cost: Double? = nil, shares: Double? = nil, account: String? = nil) {
        self.symbol = symbol
        self.code = code
        self.alias = alias
        self.cost = cost
        self.shares = shares
        self.account = account
    }

    /// Normalized symbol: always with sh/sz prefix.
    public var normalizedSymbol: String {
        if let s = symbol?.lowercased(), s.hasPrefix("sh") || s.hasPrefix("sz") {
            return s
        }
        return Self.inferSymbol(from: code)
    }

    /// Heuristic: codes starting with 5/6/9 → SH; otherwise SZ.
    /// Same rule as the existing stockline script.
    public static func inferSymbol(from code: String) -> String {
        let first = code.first.map(String.init) ?? ""
        return (["5", "6", "9"].contains(first) ? "sh" : "sz") + code
    }
}

/// Container for watchlist.json on disk.
/// Matches the format used by ~/plugins/stock-statusline/config/watchlist.json
/// so the two tools share one source of truth.
public struct Watchlist: Codable {
    public var refresh_seconds: Int?
    public var max_items: Int?
    public var items: [WatchItem]?           // legacy flat layout
    public var groups: [String: [WatchItem]]?
    public var active_group: String?

    public init(
        refresh_seconds: Int? = nil,
        max_items: Int? = nil,
        items: [WatchItem]? = nil,
        groups: [String: [WatchItem]]? = nil,
        active_group: String? = nil
    ) {
        self.refresh_seconds = refresh_seconds
        self.max_items = max_items
        self.items = items
        self.groups = groups
        self.active_group = active_group
    }

    /// Active items: prefer `groups[active_group]`, fall back to `items`.
    public var activeItems: [WatchItem] {
        if let groups, let key = active_group, let list = groups[key] {
            return list
        }
        if let groups, let first = groups.first {
            return first.value
        }
        return items ?? []
    }

    public var refreshSeconds: TimeInterval {
        TimeInterval(max(1, refresh_seconds ?? 5))
    }

    public var maxItems: Int {
        max(1, max_items ?? 4)
    }
}

/// Quote snapshot returned by Tencent's qt.gtimg.cn endpoint.
public struct Quote {
    public let symbol: String      // e.g. "sh000001"
    public let code: String        // e.g. "000001"
    public let name: String        // 上证指数 / 卫星ETF永赢 ...
    public let price: Double
    public let prevClose: Double
    public let change: Double
    public let pct: Double         // percent, signed
    public let high: Double
    public let low: Double
    public let time: String        // raw "YYYYMMDDHHmmss"

    // Extended fields (may be 0/nil for indices or instruments that don't
    // report them). Parsed relative to the "price/volume/amount" anchor field
    // so they line up across stocks / ETFs / indices alike.
    public let open: Double            // 今开
    public let volume: Double          // 成交量 (手 / lots)
    public let amount: Double          // 成交额 (万元 / 10k CNY)
    public let turnoverRate: Double?   // 换手率 % (nil for indices)
    public let pe: Double?             // 市盈率 TTM (nil for ETFs / indices)

    public init(
        symbol: String,
        code: String,
        name: String,
        price: Double,
        prevClose: Double,
        change: Double,
        pct: Double,
        high: Double,
        low: Double,
        time: String,
        open: Double,
        volume: Double,
        amount: Double,
        turnoverRate: Double?,
        pe: Double?
    ) {
        self.symbol = symbol
        self.code = code
        self.name = name
        self.price = price
        self.prevClose = prevClose
        self.change = change
        self.pct = pct
        self.high = high
        self.low = low
        self.time = time
        self.open = open
        self.volume = volume
        self.amount = amount
        self.turnoverRate = turnoverRate
        self.pe = pe
    }

    public var displayName: String { name }

    /// True for broad-market indices (上证指数 sh000xxx, 深证成指/创业板 sz399xxx,
    /// etc.). They don't report a meaningful 换手率 / 市盈率, so callers should
    /// skip those fields rather than show whatever sits in those slots.
    public var isIndex: Bool {
        symbol.hasPrefix("sh000") || symbol.hasPrefix("sz399")
    }

    /// 振幅 % = (最高 - 最低) / 昨收 * 100. Computed so it never relies on a
    /// brittle field index.
    public var amplitude: Double {
        guard prevClose > 0 else { return 0 }
        return (high - low) / prevClose * 100
    }
}

/// One point on the today-only minute-level chart.
/// Trading hours in CN: 09:30–11:30 and 13:00–15:00 (240 minutes/day).
public struct MinutePoint {
    public let minutesFromOpen: Int   // 0..239 (09:30 = 0, 11:30 = 119, 13:00 = 120, 15:00 = 239)
    public let hhmm: String           // "0930", "1100", "1305" ...
    public let price: Double

    public init(minutesFromOpen: Int, hhmm: String, price: Double) {
        self.minutesFromOpen = minutesFromOpen
        self.hhmm = hhmm
        self.price = price
    }
}
