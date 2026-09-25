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
/// Every window is scoped to one Project by its value; the Operator may open as many as they like,
/// one per Project, and `yellowhammer://project/<id>` opens the named one.
struct YellowhammerApp: App {
    /// Sparkle 2, user-initiated only (Decision Gates Ruling G-14): started once for the app's
    /// lifetime here, never in the headless launches (`AppLaunch` routes those to
    /// `HeadlessPost`/`HeadlessPermissionRequest` before `YellowhammerApp.main()` ever runs, so no
    /// update machinery exists on that path). Nothing resident beyond what Sparkle itself keeps
    /// while the app is open — no background check is scheduled (`SUEnableAutomaticChecks = NO`).
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: UpdaterDelegate(),
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup(for: ProjectID.self) { $project in
            ProjectWindow(project: $project)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                SetupMenuCommand()
                BaseRoutingTableMenuCommand()
                AgentCLIMenuCommand()
                CheckForUpdatesMenuCommand(updater: updaterController.updater)
            }
        }

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
