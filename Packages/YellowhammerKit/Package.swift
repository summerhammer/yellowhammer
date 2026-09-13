// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YellowhammerKit",
    platforms: [
        // Provisional floor, must match the Xcode project's MACOSX_DEPLOYMENT_TARGET;
        // the real rule is "the higher of Orca ADE's minimum and the SwiftUI APIs used".
        .macOS("26.5")
    ],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "EngineCommand", targets: ["EngineCommand"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.8.2"
        )
    ],
    targets: [
        .target(
            name: "Domain"
        ),
        .target(
            name: "Engine",
            dependencies: ["Domain"]
        ),
        .target(
            name: "EngineCommand",
            dependencies: [
                "Engine",
                "Domain",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "EngineCommandTests",
            dependencies: [
                "EngineCommand",
                "Domain"
            ]
        )
    ]
)
