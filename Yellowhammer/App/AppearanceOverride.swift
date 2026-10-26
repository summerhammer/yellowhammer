import AppKit

/// A DEBUG build's forced appearance, from the launch argument `-YellowhammerAppearance light|dark`, so the
/// landing-page screenshot tool (`Tools/LandingScreenshots`) captures both whatever this Mac's own setting is.
/// `-AppleInterfaceStyle` in the argument domain does not switch a SwiftUI app. Only the argument domain is
/// read, so it cannot persist through `defaults write`.
enum AppearanceOverride {
    static let argument = "YellowhammerAppearance"

    @MainActor
    static func apply() {
#if DEBUG
        let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[argument] as? String
        switch value {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
#endif
    }
}
