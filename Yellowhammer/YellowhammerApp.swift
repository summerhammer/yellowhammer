//
//  YellowhammerApp.swift
//  Yellowhammer
//
//  Created by Max Rozdobudko on 13.09.2026.
//

import Domain
import SwiftUI

/// The window app (Decision Gates Ruling, G-5). `AppLaunch` starts it for every launch that is not a
/// headless post.
///
/// Every window is scoped to one Project by its value; the Operator may open as many as they like,
/// one per Project, and `yellowhammer://project/<id>` opens the named one.
struct YellowhammerApp: App {
    var body: some Scene {
        WindowGroup(for: ProjectID.self) { $project in
            ProjectWindow(project: $project)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                SetupMenuCommand()
                BaseRoutingTableMenuCommand()
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
