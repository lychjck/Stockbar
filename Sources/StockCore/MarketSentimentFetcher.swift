import Foundation

/// Fetches market sentiment indicators: up/down counts, north-bound capital flow, total turnover.
/// Uses multiple endpoints:
///   - Up/down counts: Eastmoney API (reliable, JSON)
///   - Turnover: Tencent indices.
public final class MarketSentimentFetcher {
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

    /// Fetch market sentiment indicators.
    public func fetch() async throws -> MarketSentiment {
        // Fetch market stats (up/down counts) from SH + SZ + BJ
        let stats = try await fetchMarketStats()
        // Turnover is nice-to-have. Do not hide up/down counts if this endpoint
        // flakes out.
        let totalAmount = try? await fetchTotalAmount()
        // North-bound flow: set to 0 for now (original endpoint unavailable)
        let northFlow = 0.0

        return MarketSentiment(
            upCount: stats.upCount,
            downCount: stats.downCount,
            flatCount: stats.flatCount,
            northFlow: northFlow,
            totalAmount: totalAmount
        )
    }

    /// Fetch up/down counts from Shanghai, Shenzhen, and Beijing markets.
    /// Endpoint: https://push2.eastmoney.com/api/qt/ulist.np/get
    /// secids: 1.000001 (Shanghai), 0.399001 (Shenzhen), 0.899050 (Beijing)
    private func fetchMarketStats() async throws -> (upCount: Int, downCount: Int, flatCount: Int) {
        // Fetch Shanghai and Shenzhen markets (excluding Beijing to match broker apps)
        guard let url = URL(string: "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=1.000001,0.399001&fields=f3,f104,f105,f106") else {
            throw FetchError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("StockBar/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.emptyResponse }

        return try Self.parseMarketStatsJSON(data)
    }

    /// Parse Eastmoney JSON response and sum all returned market stats.
    static func parseMarketStatsJSON(_ data: Data) throws -> (upCount: Int, downCount: Int, flatCount: Int) {
        struct Response: Codable {
            let data: DataBlock?
            struct DataBlock: Codable {
                let diff: [Diff]?
                struct Diff: Codable {
                    let f104: Int?  // up
                    let f105: Int?  // down
                    let f106: Int?  // flat
                }
            }
        }

        let decoder = JSONDecoder()
        let resp = try decoder.decode(Response.self, from: data)
        guard let diffs = resp.data?.diff, !diffs.isEmpty else {
            throw FetchError.decodeFailed
        }

        var up = 0, down = 0, flat = 0
        for diff in diffs {
            up += diff.f104 ?? 0
            down += diff.f105 ?? 0
            flat += diff.f106 ?? 0
        }

        return (up, down, flat)
    }

    /// Fetch total turnover from Shanghai + Shenzhen + Beijing indices.
    /// Endpoint: https://qt.gtimg.cn/q=sh000001,sz399001,bj899050
    /// Response format (GBK):
    ///   v_sh000001="...~price/volume/amount~...";
    /// The composite "price/volume/amount" field contains amount in 元.
    private func fetchTotalAmount() async throws -> Double {
        guard let url = URL(string: "https://qt.gtimg.cn/q=sh000001,sz399001,bj899050") else {
            throw FetchError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("StockBar/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw FetchError.emptyResponse }

        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) else {
            throw FetchError.decodeFailed
        }

        return try Self.parseTotalAmount(text)
    }

    /// Parse total turnover from indices.
    /// Format: v_sh000001="...~price/volume/amount~...";
    /// The composite field is "price/volume/amount" where amount is in 元, convert to 亿.
    /// Note: We only sum sh000001, sz399001, and bj899050 (main indices, no double-counting)
    static func parseTotalAmount(_ text: String) throws -> Double {
        var totalAmount = 0.0

        let pattern = #"v_([a-z]{2}\d{6})="([^"]*)";"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw FetchError.decodeFailed
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))

        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let payload = ns.substring(with: m.range(at: 2))
            let parts = payload.components(separatedBy: "~")

            guard let compositeField = parts.first(where: { field in
                let segs = field.components(separatedBy: "/")
                return segs.count == 3 && Double(segs[0]) != nil && Double(segs[1]) != nil && Double(segs[2]) != nil
            }) else { continue }

            let composite = compositeField.components(separatedBy: "/")
            guard composite.count >= 3, let amountInYuan = Double(composite[2]) else { continue }
            totalAmount += amountInYuan / 100_000_000.0  // 元 -> 亿元
        }

        guard totalAmount > 0 else { throw FetchError.decodeFailed }
        return totalAmount
    }

    /// Fetch north-bound capital net inflow.
    /// Original endpoint (hk_fhszzjl) is currently unavailable, returns 0.
    private func fetchNorthFlow() async throws -> Double {
        return 0.0
    }
}
