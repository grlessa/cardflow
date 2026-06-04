// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OffloadKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OffloadKit", targets: ["OffloadKit"]),
        .executable(name: "cardflow", targets: ["cardflow"]),
        .executable(name: "CardflowApp", targets: ["CardflowApp"]),
    ],
    targets: [
        .target(
            name: "OffloadKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OffloadKitTests",
            dependencies: ["OffloadKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CardflowCLI",
            dependencies: ["OffloadKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cardflow",
            dependencies: ["CardflowCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CardflowCLITests",
            dependencies: ["CardflowCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CardflowApp",
            dependencies: ["OffloadKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
