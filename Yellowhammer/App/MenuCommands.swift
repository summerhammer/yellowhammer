import Config
import Sparkle
import SwiftUI

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

/// Menu command to install, update, or uninstall the Command Line Tool symlink at `/usr/local/bin/yh`.
struct CommandLineToolMenuCommand: View {
    @Bindable var model: CommandLineToolModel

    var body: some View {
        Button(title) {
            switch model.state {
            case .notInstalled:
                model.promptInstall()
            case .dangling(_), .mismatched(_):
                model.promptUpdate()
            case .installed:
                model.promptUninstall()
            }
        }
        .disabled(!isEnabled)
    }

    private var isEnabled: Bool {
        switch model.state {
        case .notInstalled, .installed, .dangling(_):
            true
        case .mismatched(_):
            model.isSymlink
        }
    }

    private var title: String {
        switch model.state {
        case .notInstalled:
            "Install Command Line Tool…"
        case .dangling(_), .mismatched(_):
            "Update Command Line Tool…"
        case .installed:
            "Uninstall Command Line Tool…"
        }
    }
}

