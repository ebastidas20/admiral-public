// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AdmiralCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AdmiralCore", targets: ["AdmiralCore"]),
    ],
    targets: [
        .target(
            name: "AdmiralCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AdmiralCoreTests",
            dependencies: ["AdmiralCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
