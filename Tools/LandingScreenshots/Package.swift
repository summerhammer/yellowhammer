// swift-tools-version: 6.2
import PackageDescription

// A standalone tool for the landing page's app screenshots: it writes stub-data configuration directories
// the app renders, and captures a Debug build of the app showing them. Nothing in the app, `yh` or any test links it.
let package = Package(
    name: "LandingScreenshots",
    platforms: [
        // Same as Packages/YellowhammerKit, whose products this links.
        .macOS("26.0")
    ],
    products: [
        .library(name: "Showcase", targets: ["Showcase"]),
        .executable(name: "showcase-journals", targets: ["showcase-journals"]),
        .executable(name: "landing-screenshots", targets: ["landing-screenshots"])
    ],
    dependencies: [
        .package(path: "../../Packages/YellowhammerKit")
    ],
    targets: [
        .target(
            name: "Showcase",
            dependencies: [
                .product(name: "Config", package: "YellowhammerKit"),
                .product(name: "Domain", package: "YellowhammerKit"),
                .product(name: "Journal", package: "YellowhammerKit"),
                .product(name: "Pulse", package: "YellowhammerKit")
            ]
        ),
        .executableTarget(
            name: "showcase-journals",
            dependencies: ["Showcase"]
        ),
        // Launches a Debug build of the app per shot and captures its window; see scripts/landing-screenshots.sh.
        .executableTarget(
            name: "landing-screenshots",
            dependencies: ["Showcase"]
        )
    ],
    swiftLanguageModes: [.v6]
)
