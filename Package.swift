// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StockSuite",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "StockBar", targets: ["StockBar"]),
    ],
    targets: [
        // Pure data layer — models, fetchers, market-hours, on-disk store.
        // No AppKit, no UI. Shared by every front-end target.
        .target(
            name: "StockCore",
            path: "Sources/StockCore"
        ),
        // Status-bar UI (NSPopover, charts, desktop card).
        .executableTarget(
            name: "StockBar",
            dependencies: ["StockCore"],
            path: "Sources/StockBar"
        ),
    ]
)
