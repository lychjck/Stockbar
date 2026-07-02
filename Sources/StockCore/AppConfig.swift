import Foundation

/// Application-wide UI preferences — distinct from the watchlist.json data
/// file. Stored in UserDefaults so we don't pollute the shared config that
/// `stockline` (or other tools) might read.
public struct AppConfig: Codable {
    public var enableMenuBar: Bool
    public var enableTouchBar: Bool

    public init(
        enableMenuBar: Bool = true,
        enableTouchBar: Bool = true
    ) {
        self.enableMenuBar = enableMenuBar
        self.enableTouchBar = enableTouchBar
    }

    // MARK: - Persistence

    private static let defaultsKey = "StockBar.AppConfig"

    public static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()  // default: both enabled
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
