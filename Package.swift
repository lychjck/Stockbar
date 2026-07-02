// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StockSuite",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // Unified app: menu bar + Touch Bar in one executable.
        .executable(name: "StockBar", targets: ["StockBar"]),
    ],
    targets: [
        // Pure data layer — models, fetchers, market-hours, on-disk store.
        // No AppKit, no UI. Shared by every front-end target.
        .target(
            name: "StockCore",
            path: "Sources/StockCore"
        ),
        // Touch Bar UI module — controllers, views, DFR bridge.
        // Independent module that can be reused.
        .target(
            name: "StockTouchBar",
            dependencies: ["StockCore"],
            path: "Sources/StockTouchBar"
        ),
        // Unified UI (menu bar + Touch Bar + desktop card).
        .executableTarget(
            name: "StockBar",
            dependencies: ["StockCore", "StockTouchBar"],
            path: "Sources/StockBar"
        ),
    ]
)
