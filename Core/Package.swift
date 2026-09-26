// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BitMeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BitMeCore", targets: ["BitMeCore"]),
        .executable(name: "bitme-cli", targets: ["BitMeCLI"]),
    ],
    dependencies: [
        .package(path: "../../spacetimedb-swift-sdk")
    ],
    targets: [
        .target(
            name: "BitMeCore",
            dependencies: [
                .product(name: "SpacetimeDB", package: "spacetimedb-swift-sdk"),
                .product(name: "BSATN", package: "spacetimedb-swift-sdk"),
            ],
            path: "Sources/BitMeCore"
        ),
        .executableTarget(
            name: "BitMeCLI",
            dependencies: ["BitMeCore"],
            path: "Sources/BitMeCLI"
        ),
        .testTarget(
            name: "BitMeCoreTests",
            dependencies: ["BitMeCore"],
            path: "Tests/BitMeCoreTests"
        ),
    ]
)
