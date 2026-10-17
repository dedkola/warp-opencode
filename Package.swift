// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WarpGoBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "WarpGoBridge", targets: ["WarpGoBridge"])
    ],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "WarpGoBridge", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ],
    swiftLanguageModes: [.v5]
)
