// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BitMeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BitMeCore", targets: ["BitMeCore"]),
        .executable(name: "bitme-cli", targets: ["BitMeCLI"]),
    ],
    targets: [
        .target(
            name: "BitMeCore",
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
