// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YellowhammerKit",
    platforms: [
        // Must match the Xcode project's MACOSX_DEPLOYMENT_TARGET. macOS 26.0 is the higher of
        // Orca ADE's 12.0 minimum and the APIs the app may use: spec Decision Gates Ruling, G-2.
        .macOS("26.0")
    ],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Config", targets: ["Config"]),
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
            name: "Config",
            dependencies: ["Domain"]
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
            name: "ConfigTests",
            dependencies: [
                "Config",
                "Domain"
            ],
            resources: [.copy("Fixtures")]
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
