// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StockBar",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "StockBar", targets: ["StockBar"])
    ],
    targets: [
        .executableTarget(
            name: "StockBar",
            path: "Sources/StockBar"
        )
    ]
)
