import XCTest
@testable import StockCore

final class WatchlistStoreTests: XCTestCase {
    func testWatchForChangesFallsBackToParentDirectoryWhenConfigIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockBarTests-\(UUID().uuidString)", isDirectory: true)
        let configPath = root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("watchlist.json")
            .path
        let store = WatchlistStore(configPath: configPath)

        let source = store.watchForChanges {}

        XCTAssertNotNil(source)
        source?.cancel()
    }
}
