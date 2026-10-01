import Sparkle
import SwiftUI

/// A menu command needs its own `@Environment` to read `openWindow`: the App's `.commands` builder does
/// not otherwise resolve scene environment values.
struct SetupMenuCommand: View {
    static let windowID = "setup"

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Setup…") { openWindow(id: Self.windowID) } // glossary:ignore GL001
    }
}

/// Opens the Settings window on the Project the key main window shows. With no main window key (the
/// Settings window itself, say), it asks for no Project, and Settings stays where it was.
struct SettingsMenuCommand: View {
    let request: SettingsRequest
    @FocusedValue(\.overviewProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings\u{2026}") {
            request.request(project)
            openWindow(id: SettingsWindow.windowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Sparkle's documented KVO-compliant `canCheckForUpdates`, observed so the menu item disables
/// itself while a check is already running instead of letting the Operator start a second one.
struct CheckForUpdatesMenuCommand: View {
    let updater: SPUUpdater

    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}
