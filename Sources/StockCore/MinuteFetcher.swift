import Foundation

/// Fetches today's minute-level price points (09:30–15:00, ~240 points).
/// Endpoint: https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh000001
/// Response is JSON; the actual point list lives at:
///     data.<symbol>.data.data  (array of strings: "HHMM price volume turnover")
public final class MinuteFetcher {
    public enum FetchError: Error {
        case invalidURL
        case http(Int)
        case noData
        case parseFailed
    }

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    /// Fetch minute points for one symbol (e.g. "sh000001").
    public func fetch(symbol: String) async throws -> [MinutePoint] {
        guard let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(symbol)") else {
            throw FetchError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("StockBar/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(http.statusCode)
        }
        return try Self.parse(data: data, symbol: symbol)
    }

    public static func parse(data: Data, symbol: String) throws -> [MinutePoint] {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataDict = json["data"] as? [String: Any],
            let symbolEntry = dataDict[symbol] as? [String: Any],
            let inner = symbolEntry["data"] as? [String: Any],
            let raw = inner["data"] as? [String]
        else {
            throw FetchError.parseFailed
        }
        var out: [MinutePoint] = []
        out.reserveCapacity(raw.count)
        for line in raw {
            // Each line looks like: "0930 4117.79 5811064 16173033562.60"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let hhmm = parts[0]
            guard let price = Double(parts[1]) else { continue }
            guard let m = Self.minutesFromOpen(hhmm: hhmm) else { continue }
            out.append(MinutePoint(minutesFromOpen: m, hhmm: hhmm, price: price))
        }
        return out
    }

    /// Map "HHMM" to minutes since 09:30, treating 11:30→13:00 as one continuous gap.
    /// 09:30 → 0, 11:30 → 120, 13:00 → 120, 15:00 → 240.
    /// Returns nil if outside [09:30, 15:00].
    public static func minutesFromOpen(hhmm: String) -> Int? {
        guard hhmm.count == 4, let v = Int(hhmm) else { return nil }
        let hour = v / 100
        let minute = v % 100
        if minute < 0 || minute > 59 { return nil }
        let totalMin = hour * 60 + minute
        let open = 9 * 60 + 30
        let lunchStart = 11 * 60 + 30
        let lunchEnd = 13 * 60
        let close = 15 * 60
        if totalMin < open || totalMin > close { return nil }
        if totalMin <= lunchStart {
            return totalMin - open
        }
        if totalMin >= lunchEnd {
            return (lunchStart - open) + (totalMin - lunchEnd)
        }
        // Inside lunch break — shouldn't appear in data, snap to lunchStart.
        return lunchStart - open
    }
}
