#if DEBUG
import AppKit
import SwiftUI

/// The app's theme colours, mirrored from `Theme+Defaults.swift` because this package never links the
/// app. If the app's values change, copy them here again.
enum SettingsTheme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let attention = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let success = Color(light: 0x71C171, dark: 0x408140)
    static let info = Color(light: 0x46B8DA, dark: 0x269ABC)
    static let error = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let neutral = Color(light: 0x8E8E93, dark: 0x98989D)
    /// Primary at 5%, the fill behind boxed groups.
    static let surface = Color.primary.opacity(0.05)
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
#endif
