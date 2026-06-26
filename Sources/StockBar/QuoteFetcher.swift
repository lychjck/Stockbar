import Foundation

/// Fetches realtime quotes from Tencent's free quote endpoint.
/// Endpoint: https://qt.gtimg.cn/q=sh000001,sz159770
/// Response is GBK-encoded text in the form:
///     v_sh000001="1~上证指数~000001~3000.00~...";\n
final class QuoteFetcher {
    enum FetchError: Error {
        case invalidURL
        case emptyResponse
        case decodeFailed
        case http(Int)
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Fetch quotes for the given symbols (e.g. ["sh000001", "sz159770"]).
    /// Returns parsed Quote objects in arbitrary order; map by `symbol` to align with watchlist.
    func fetch(symbols: [String]) async throws -> [Quote] {
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
    /// Field indexes (1-based in raw spec, here 0-based after split):
    ///   1: name, 2: code, 3: price, 4: prev_close,
    ///   30: time (YYYYMMDDhhmmss), 31: change, 32: pct,
    ///   33: high, 34: low
    static func parse(_ text: String) -> [Quote] {
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
            if parts.count < 35 { continue }
            guard
                let price = Double(parts[3]),
                let prevClose = Double(parts[4]),
                let pct = Double(parts[32]),
                let high = Double(parts[33]),
                let low = Double(parts[34])
            else { continue }
            let change: Double = Double(parts[31]) ?? (price - prevClose)
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
                time: parts.count > 30 ? parts[30] : ""
            )
            result.append(q)
        }
        return result
    }
}
