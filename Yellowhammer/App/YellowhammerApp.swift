//
//  YellowhammerApp.swift
//  Yellowhammer
//
//  Created by Max Rozdobudko on 13.09.2026.
//

import Domain
import Sparkle
import SwiftUI

/// The window app (Decision Gates Ruling, G-5). `AppLaunch` starts it for every launch that is not a
/// headless post.
///
/// The main window (`OverviewWindow`) is scoped to one Project by its value. The Operator may open as
/// many main windows as they like, and `yellowhammer://project/<id>` opens the one for the named
/// Project. Both groups that present a `ProjectID` are opened by their id, never by value alone, so a
/// value can never pick the wrong one.
struct YellowhammerApp: App {
    /// Sparkle 2, user-initiated only (Decision Gates Ruling G-14): started once for the app's
    /// lifetime here, never in the headless launches (`AppLaunch` routes those to
    /// `HeadlessPost`/`HeadlessPermissionRequest` before `YellowhammerApp.main()` ever runs, so no
    /// update machinery exists on that path). Nothing resident beyond what Sparkle itself keeps
    /// while the app is open — no background check is scheduled (`SUEnableAutomaticChecks = NO`).
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Never under a UI test (`-YellowhammerEngineStub`, the same override `SetupEngine` reads):
        // Sparkle's own first-check UI can pop a blocking "Unable to Check for Updates" alert with no
        // network reachable in that sandbox, stealing focus from every window XCUITest drives. Debug
        // builds also have no provisioned EdDSA key, so leave Sparkle stopped instead of asking it to
        // decode an empty key on every Xcode launch.
        let isUITest = UserDefaults.standard
            .volatileDomain(forName: UserDefaults.argumentDomain)[SetupEngine.stubArgument] != nil
#if DEBUG
        let shouldStartUpdater = false
#else
        let shouldStartUpdater = !isUITest
#endif
        updaterController = SPUStandardUpdaterController(
            startingUpdater: shouldStartUpdater,
            updaterDelegate: UpdaterDelegate(),
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        // First, so it is the window the app opens on, and the one File > New Window opens.
        WindowGroup(id: OverviewWindow.windowID, for: ProjectID.self) { $project in
            OverviewWindow(project: $project)
        }
        // Room for the three columns at their ideal widths. The minimum comes from the columns' own.
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [ProjectDeepLink.scheme])
        .commands {
            InspectorCommands()
            CommandGroup(after: .appInfo) {
                SetupMenuCommand()
                ProjectWindowMenuCommand()
                BaseRoutingTableMenuCommand()
                AgentCLIMenuCommand()
                CheckForUpdatesMenuCommand(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsWindow()
        }

        // Temporary: the screens the main window does not carry yet, until P18.14 moves the last of them.
        // A deep link never opens this window; it opens the main window.
        WindowGroup("Project", id: ProjectWindow.windowID, for: ProjectID.self) { $project in
            ProjectWindow(project: $project)
        }
        .handlesExternalEvents(matching: [])

        // Not Project-scoped: declaring a new Project happens here, never in a Project window.
        Window("Setup", id: SetupMenuCommand.windowID) {
            SetupWizardView()
        }

        // Not Project-scoped: the base Routing Table is machine-wide, shared by every Project.
        Window("Base Routing Table", id: BaseRoutingTableMenuCommand.windowID) {
            BaseRoutingTableView()
        }
        .defaultSize(width: 560, height: 480)

        // Not Project-scoped: the declared CLI Adapters and the Ledger are both machine-wide, so one
        // Probe run serves every Project.
        Window("Agent CLIs", id: AgentCLIMenuCommand.windowID) {
            AgentCLIView()
        }
        .defaultSize(width: 640, height: 520)
    }
}

/// A menu command needs its own `@Environment` to read `openWindow`: the App's `.commands` builder does
/// not otherwise resolve scene environment values.
private struct SetupMenuCommand: View {
    static let windowID = "setup"

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Setup…") { openWindow(id: Self.windowID) } // glossary:ignore GL001
    }
}

/// Opens the temporary Project Window for the Project the key main window shows. With no main window
/// key, it opens the window for the first configured Project.
private struct ProjectWindowMenuCommand: View {
    @FocusedValue(\.overviewProject) private var project
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Project Window\u{2026}") {
            if let project {
                openWindow(id: ProjectWindow.windowID, value: project)
            } else {
                openWindow(id: ProjectWindow.windowID)
            }
        }
    }
}

/// A menu command needs its own `@Environment` to read `openWindow`: the App's `.commands` builder does
/// not otherwise resolve scene environment values.
private struct BaseRoutingTableMenuCommand: View {
    static let windowID = "base-routing-table"

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Base Routing Table…") { openWindow(id: Self.windowID) }
    }
}

/// A menu command needs its own `@Environment` to read `openWindow`: the App's `.commands` builder does
/// not otherwise resolve scene environment values.
private struct AgentCLIMenuCommand: View {
    static let windowID = "agent-clis"

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agent CLIs…") { openWindow(id: Self.windowID) }
    }
}

/// Sparkle's documented KVO-compliant `canCheckForUpdates`, observed so the menu item disables
/// itself while a check is already running instead of letting the Operator start a second one.
private struct CheckForUpdatesMenuCommand: View {
    let updater: SPUUpdater

    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}
