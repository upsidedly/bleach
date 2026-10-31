// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bleach",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bleach", targets: ["BleachCLI"]),
        .executable(name: "BleachApp", targets: ["BleachApp"])
    ],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "BleachFS", publicHeadersPath: "include"),
        .target(name: "BleachCore", dependencies: ["BleachFS", "ZIPFoundation"]),
        .executableTarget(name: "BleachCLI", dependencies: ["BleachCore"]),
        .executableTarget(name: "BleachApp", dependencies: ["BleachCore"]),
        .testTarget(name: "BleachCoreTests", dependencies: ["BleachCore", "BleachFS", "ZIPFoundation"])
    ],
    swiftLanguageModes: [.v6]
)
