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
        .library(name: "Journal", targets: ["Journal"]),
        .library(name: "Ledger", targets: ["Ledger"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "LinearAdapter", targets: ["LinearAdapter"]),
        .library(name: "OrcaADEAdapter", targets: ["OrcaADEAdapter"]),
        .library(name: "Repositories", targets: ["Repositories"]),
        .library(name: "EngineCommand", targets: ["EngineCommand"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.8.2"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.11.1"
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
            name: "Journal",
            dependencies: [
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "Ledger",
            dependencies: [
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "Repositories",
            dependencies: ["Domain"]
        ),
        .target(
            name: "Engine",
            dependencies: ["Domain", "Journal", "Repositories"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "LinearAdapter",
            dependencies: ["Domain"]
        ),
        .target(
            name: "OrcaADEAdapter",
            dependencies: ["Domain"]
        ),
        .target(
            name: "EngineCommand",
            dependencies: [
                "Engine",
                "Domain",
                "Config",
                "Journal",
                "LinearAdapter",
                "OrcaADEAdapter",
                "Repositories",
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
            name: "JournalTests",
            dependencies: [
                "Journal",
                "Domain"
            ]
        ),
        .testTarget(
            name: "LedgerTests",
            dependencies: [
                "Ledger",
                "Domain"
            ]
        ),
        .testTarget(
            name: "LinearAdapterTests",
            dependencies: [
                "LinearAdapter",
                "Domain"
            ]
        ),
        .testTarget(
            name: "OrcaADEAdapterTests",
            dependencies: [
                "OrcaADEAdapter",
                "Domain"
            ]
        ),
        .testTarget(
            name: "RepositoriesTests",
            dependencies: [
                "Repositories",
                "Domain",
                "Journal"
            ]
        ),
        .testTarget(
            name: "EngineCommandTests",
            dependencies: [
                "EngineCommand",
                "Config",
                "Engine",
                "Domain",
                "Journal",
                "Repositories"
            ]
        )
    ]
)
