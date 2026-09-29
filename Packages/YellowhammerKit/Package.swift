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
        .library(name: "Pulse", targets: ["Pulse"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "LinearAdapter", targets: ["LinearAdapter"]),
        .library(name: "OrcaADEAdapter", targets: ["OrcaADEAdapter"]),
        .library(name: "GitHubAdapter", targets: ["GitHubAdapter"]),
        .library(name: "Repositories", targets: ["Repositories"]),
        .library(name: "CLIAdapters", targets: ["CLIAdapters"]),
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
        ),
        .package(
            url: "https://github.com/swiftlang/swift-subprocess",
            from: "1.0.0"
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
            name: "Pulse",
            dependencies: [
                "Domain",
                "Config",
                "Journal"
            ]
        ),
        .target(
            name: "Repositories",
            dependencies: [
                "Domain",
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "Engine",
            dependencies: [
                "Domain",
                "Journal",
                "Repositories",
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "LinearAdapter",
            dependencies: ["Domain"]
        ),
        .target(
            name: "OrcaADEAdapter",
            dependencies: [
                "Domain",
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "GitHubAdapter",
            dependencies: ["Domain"]
        ),
        .target(
            name: "CLIAdapters",
            dependencies: [
                "Domain",
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "EngineCommand",
            dependencies: [
                "Engine",
                "Domain",
                "Config",
                "Journal",
                "Ledger",
                "LinearAdapter",
                "OrcaADEAdapter",
                "GitHubAdapter",
                "Repositories",
                "CLIAdapters",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "ProcessTestSupport",
            path: "Tests/ProcessTestSupport"
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["Domain"]
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
            name: "PulseTests",
            dependencies: [
                "Pulse",
                "Config",
                "Journal",
                "Domain"
            ]
        ),
        .testTarget(
            name: "LinearAdapterTests",
            dependencies: [
                "LinearAdapter",
                "Domain",
                "Config"
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
            name: "GitHubAdapterTests",
            dependencies: [
                "GitHubAdapter",
                "Domain"
            ]
        ),
        .testTarget(
            name: "RepositoriesTests",
            dependencies: [
                "Repositories",
                "Domain",
                "Journal",
                "ProcessTestSupport"
            ]
        ),
        .testTarget(
            name: "CLIAdaptersTests",
            dependencies: [
                "CLIAdapters",
                "Domain"
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
                "Ledger",
                "Repositories",
                "ProcessTestSupport"
            ]
        )
    ]
)
