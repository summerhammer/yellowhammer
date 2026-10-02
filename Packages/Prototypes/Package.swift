// swift-tools-version: 6.2
import PackageDescription

// Throwaway screen prototypes, rendered in Xcode Previews from fixtures alone, so a preview builds
// neither the app nor `yh`. One target per screen. The app never links this package; delete a
// screen's target once that screen is built for real.
let package = Package(
    name: "Prototypes",
    platforms: [
        // The same minimum as YellowhammerKit and the app.
        .macOS("26.0")
    ],
    products: [
        // A product per target only so Xcode offers a scheme to render its previews.
        .library(name: "PulsePrototypes", targets: ["PulsePrototypes"]),
        .library(name: "AddProjectPrototypes", targets: ["AddProjectPrototypes"])
    ],
    dependencies: [
        .package(path: "../YellowhammerKit")
    ],
    targets: [
        .target(
            name: "PulsePrototypes",
            dependencies: [
                .product(name: "Domain", package: "YellowhammerKit"),
                .product(name: "Pulse", package: "YellowhammerKit")
            ],
            // The isolation the code had in the app target.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Hub4, the Add Project sheet's chosen layout, kept as the reference for `Yellowhammer/Features/AddProject`.
        // Plain fixtures only: it reads no Journal and runs no `yh`.
        .target(
            name: "AddProjectPrototypes",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
