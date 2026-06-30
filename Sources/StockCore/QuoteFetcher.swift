import Foundation

/// Fetches realtime quotes from Tencent's free quote endpoint.
/// Endpoint: https://qt.gtimg.cn/q=sh000001,sz159770
/// Response is GBK-encoded text in the form:
///     v_sh000001="1~上证指数~000001~3000.00~...";\n
public final class QuoteFetcher {
    public enum FetchError: Error {
        case invalidURL
        case emptyResponse
        case decodeFailed
        case http(Int)
    }

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Fetch quotes for the given symbols (e.g. ["sh000001", "sz159770"]).
    /// Returns parsed Quote objects in arbitrary order; map by `symbol` to align with watchlist.
    public func fetch(symbols: [String]) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        let joined = symbols.joined(separator: ",")
        guard let url = URL(string: "https://qt.gtimg.cn/q=\(joined)") else {
            throw FetchError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("StockBar/0.1", forHTTPHeaderField: "User-Agent")
        // Tencent endpoint requires Referer for some symbols
        req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.emptyResponse }

        // Tencent returns GBK. Use CFStringConvertEncodingToNSStringEncoding for GB18030.
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) else {
            throw FetchError.decodeFailed
        }

        return Self.parse(text)
    }

    /// Parse Tencent quote text. Each line looks like:
    ///   v_sh000001="1~上证指数~000001~3000.00~3010.00~...";
    ///
    /// Fixed-position fields (0-based after splitting on `~`):
    ///   1: name, 2: code, 3: price, 4: prev_close, 5: open
    ///
    /// The remaining fields (change / pct / high / low / volume / amount /
    /// turnover / PE) sit at *different* absolute indices depending on the
    /// instrument type — indices (上证指数 …) carry an extra "沪股通/深股通"
    /// block that shifts everything by one versus regular stocks / ETFs.
    /// Hard-coding `parts[32]` therefore mis-reads every index (e.g. 上证指数
    /// would show its 涨跌额 as the 涨跌幅).
    ///
    /// Instead we anchor on the one field whose format is stable across all
    /// types: the "price/volume/amount" combo (e.g. "4116.95/38158261/45713…").
    /// Call its index K; then for both stocks and indices:
    ///   change = K-4, pct = K-3, high = K-2, low = K-1,
    ///   volume = K+1 (手), amount = K+2 (万元), turnover = K+3 (%), PE = K+4
    public static func parse(_ text: String) -> [Quote] {
        var result: [Quote] = []
        // Match assignments: v_<symbol>="..."
        let pattern = #"v_([a-z]{2}\d{6})="([^"]*)";"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let symbol = ns.substring(with: m.range(at: 1))
            let payload = ns.substring(with: m.range(at: 2))
            let parts = payload.components(separatedBy: "~")
            if parts.count < 6 { continue }
            guard
                let price = Double(parts[3]),
                let prevClose = Double(parts[4])
            else { continue }

            // Locate the "price/volume/amount" anchor: the first field that
            // splits into 3 numeric segments whose first segment matches price.
            guard let k = anchorIndex(in: parts, price: price) else { continue }

            // Defensive bounds: we need K-4 … K+4 to exist.
            guard k >= 5, k + 2 < parts.count else { continue }

            let change = Double(parts[k - 4]) ?? (price - prevClose)
            let pct = Double(parts[k - 3]) ?? 0
            let high = Double(parts[k - 2]) ?? price
            let low = Double(parts[k - 1]) ?? price
            let time = parts[k - 5]
            let open = Double(parts[5]) ?? prevClose
            let volume = Double(parts[k + 1]) ?? 0
            let amount = Double(parts[k + 2]) ?? 0
            let turnover = (k + 3 < parts.count) ? Double(parts[k + 3]) : nil
            let pe = (k + 4 < parts.count) ? Double(parts[k + 4]) : nil

            let q = Quote(
                symbol: symbol,
                code: parts[2].isEmpty ? String(symbol.dropFirst(2)) : parts[2],
                name: parts[1],
                price: price,
                prevClose: prevClose,
                change: change,
                pct: pct,
                high: high,
                low: low,
                time: time,
                open: open,
                volume: volume,
                amount: amount,
                turnoverRate: turnover,
                pe: pe
            )
            result.append(q)
        }
        return result
    }

    /// Find the index of the "price/volume/amount" combo field. It is the field
    /// that contains exactly two '/' separators and whose first segment equals
    /// the current price (within rounding). Searched from index 6 onward to skip
    /// the leading name/code/price block.
    private static func anchorIndex(in parts: [String], price: Double) -> Int? {
        for i in 6..<parts.count {
            let field = parts[i]
            guard field.contains("/") else { continue }
            let segs = field.components(separatedBy: "/")
            guard segs.count == 3, let first = Double(segs[0]) else { continue }
            // First segment is the price; allow tiny rounding differences.
            if abs(first - price) < 0.0001 || first == price {
                return i
            }
        }
        return nil
    }
}
