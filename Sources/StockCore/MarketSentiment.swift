import Foundation

/// Market sentiment indicators: up/down counts, north-bound capital flow, total turnover.
public struct MarketSentiment {
    /// Number of stocks up today.
    public let upCount: Int
    /// Number of stocks down today.
    public let downCount: Int
    /// Number of stocks flat (unchanged).
    public let flatCount: Int
    /// Total stocks traded.
    public var totalCount: Int { upCount + downCount + flatCount }
    /// Up/down ratio (0.0 - 1.0), where > 0.6 is bullish, < 0.4 is bearish.
    public var upDownRatio: Double {
        let sum = upCount + downCount
        return sum > 0 ? Double(upCount) / Double(sum) : 0.5
    }

    /// North-bound capital net inflow today (billion CNY). Positive = inflow, negative = outflow.
    public let northFlow: Double

    /// Total turnover of Shanghai + Shenzhen markets (billion CNY).
    public let totalAmount: Double?

    public init(upCount: Int, downCount: Int, flatCount: Int, northFlow: Double, totalAmount: Double?) {
        self.upCount = upCount
        self.downCount = downCount
        self.flatCount = flatCount
        self.northFlow = northFlow
        self.totalAmount = totalAmount
    }
}

/// One sector (industry) index.
public struct SectorIndex {
    /// Tencent symbol, e.g. "sz880301"
    public let symbol: String
    /// Sector name, e.g. "电子信息"
    public let name: String
    /// Current price
    public let price: Double
    /// Percent change today
    public let pct: Double

    public init(symbol: String, name: String, price: Double, pct: Double) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.pct = pct
    }
}
