#if DEBUG
import AppKit
import SwiftUI

/// The Overview's theme colours, mirrored from the app's `Theme+Defaults.swift` because this package
/// never links the app. Colours and typography are fixed for the wizard prototypes: every variant draws
/// with these tokens and the system text styles, and differs only in layout and components. If the app's
/// values change, copy them here again.
enum WizardTheme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let attention = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let active = Color(light: 0x2EB250, dark: 0x30D158)
    static let success = Color(light: 0x71C171, dark: 0x408140)
    static let info = Color(light: 0x46B8DA, dark: 0x269ABC)
    static let warning = Color(light: 0xFFCC00, dark: 0xFFD60A)
    static let error = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let neutral = Color(light: 0x8E8E93, dark: 0x98989D)
    /// Primary at 5%, the fill behind tiles and boxed groups.
    static let surface = Color.primary.opacity(0.05)
    static let onColor = Color.white
}

extension Color {
    /// A colour that follows the appearance, as the app's ThemeKit tokens do.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension WizardStepStatus {
    /// Done is `success`, a problem is `error`, the current step is the system accent, and the rest are
    /// `neutral` — the same roles the Pulse uses. Colour is never the only signal: every mark has a label
    /// or a symbol.
    var color: Color {
        switch self {
        case .done: WizardTheme.success
        case .problem: WizardTheme.error
        case .current: WizardTheme.accent
        case .upcoming: WizardTheme.neutral
        }
    }

    var systemImage: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .current: "circle.inset.filled"
        case .upcoming: "circle"
        }
    }
}
#endif
