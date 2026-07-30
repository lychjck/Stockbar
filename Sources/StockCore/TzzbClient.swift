import Foundation

/// Response from tzzb GET /api/positions
public struct TzzbPositionsResponse: Codable {
    public let positions: [TzzbPosition]
    public let summary: TzzbSummary

    public struct TzzbSummary: Codable {
        public let value: Double
        public let hold_profit: Double
        public let day_profit: Double
        public let count: Int
    }
}

/// One position item from tzzb
public struct TzzbPosition: Codable {
    public let account: String?
    public let accounts: [String]?
    public let category: String?
    public let code: String
    public let name: String
    public let count: Double
    public let cost: Double
    public let price: Double
    public let value: Double
    public let hold_profit: Double
    public let hold_rate: Double
    public let day_profit: Double
    public let day_rate: Double

    enum CodingKeys: String, CodingKey {
        case account
        case accounts
        case category
        case code
        case name
        case count
        case cost
        case price
        case value
        case hold_profit
        case hold_rate
        case day_profit
        case day_rate
    }
}

/// Client for tzzb HTTP API
public final class TzzbClient {
    public let baseURL: String
    private let session: URLSession

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.session = session
    }

    /// Fetch positions from tzzb. Filters to stock type only (no funds).
    /// Returns nil if the API is unreachable or returns an error.
    public func fetchPositions() async -> [TzzbPosition]? {
        guard let url = URL(string: "\(baseURL)/api/positions/merged?type=stock") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let decoder = JSONDecoder()
            let resp = try decoder.decode(TzzbPositionsResponse.self, from: data)
            return resp.positions
        } catch {
            // Silently fail — tzzb might not be running
            return nil
        }
    }

    /// Convert tzzb positions to WatchItem array
    public static func positionsToWatchItems(_ positions: [TzzbPosition]) -> [WatchItem] {
        positions.map { pos in
            // 优先使用 accounts 数组（合并持仓），否则使用单个 account
            let accountLabel: String
            if let accounts = pos.accounts, !accounts.isEmpty {
                accountLabel = accounts.joined(separator: "+")
            } else if let account = pos.account {
                accountLabel = account
            } else {
                accountLabel = ""
            }

            return WatchItem(
                symbol: nil,  // will be inferred from code
                code: pos.code,
                alias: pos.name,
                cost: pos.cost,
                shares: pos.count,
                account: accountLabel
            )
        }
    }
}
