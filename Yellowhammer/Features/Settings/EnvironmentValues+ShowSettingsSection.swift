import SwiftUI

extension EnvironmentValues {
    /// Takes the Settings window to a section. A pane calls this instead of opening a window, so every
    /// move is a visit in the window's history.
    @Entry var showSettingsSection: @MainActor (SettingsSection) -> Void = { _ in }
}
