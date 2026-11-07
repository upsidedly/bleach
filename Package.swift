// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bleach",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bleach", targets: ["BleachCLI"]),
        .executable(name: "BleachApp", targets: ["BleachApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // Upstream concurrency and stdio-lifecycle fixes after0.11.0; pinned, no local SDK patches.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "960e77e55acafc266f4d3ca2994a4c8a81e87d19")
    ],
    targets: [
        .target(name: "BleachFS", publicHeadersPath: "include"),
        .target(name: "BleachCore", dependencies: ["BleachFS", "ZIPFoundation"]),
        .target(name: "BleachMCP", dependencies: ["BleachCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "BleachCLI", dependencies: ["BleachCore", "BleachMCP"]),
        .executableTarget(name: "BleachApp", dependencies: ["BleachCore"]),
        .testTarget(name: "BleachCoreTests", dependencies: ["BleachCore", "BleachFS", "ZIPFoundation"])
    ],
    swiftLanguageModes: [.v6]
)
