// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MirrorBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MirrorBridge",
            targets: ["MirrorBridge"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MirrorBridge",
            path: "Sources/MirrorBridge"
        ),
        .testTarget(
            name: "MirrorBridgeTests",
            dependencies: ["MirrorBridge"],
            path: "Tests/MirrorBridgeTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
