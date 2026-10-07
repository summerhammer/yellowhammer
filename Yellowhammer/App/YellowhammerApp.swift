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
    /// The Project the Settings window preselects when a gesture opens it. One for the app, so the main
    /// windows can ask and the Settings window can answer.
    @State private var settingsRequest = SettingsRequest()
    /// Told when a Project is added or removed, so every window that lists Projects reads its configuration
    /// again.
    @State private var projectListChanges = ProjectListChanges()
    /// The ids links have named, so a main window can tell a linked unknown id from a stale one.
    @State private var deepLinkedProjects = DeepLinkedProjects()
    /// State and actions for the Command Line Tool symlink at `/usr/local/bin/yh`.
    @State private var commandLineTool = CommandLineToolModel()

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
                .addProjectSheet()
                .environment(settingsRequest)
                .environment(projectListChanges)
                .environment(deepLinkedProjects)
                .environment(commandLineTool)
                .commandLineToolDialogs(model: commandLineTool)
                .onAppear {
                    commandLineTool.checkOnLaunch()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    commandLineTool.refresh()
                }
        }
        // Room for the three columns at their ideal widths. The minimum comes from the columns' own.
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [ProjectDeepLink.scheme])
        .commands {
            InspectorCommands()
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand(request: settingsRequest)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuCommand(updater: updaterController.updater)
                CommandLineToolMenuCommand(model: commandLineTool)
            }
        }

        // Not Project-scoped: its own sidebar picks the Project. A deep link never opens this window.
        Window("Settings", id: SettingsWindow.windowID) {
            SettingsWindow()
                .addProjectSheet()
                .environment(settingsRequest)
                .environment(projectListChanges)
                .environment(commandLineTool)
                .commandLineToolDialogs(model: commandLineTool)
        }
        .defaultSize(width: 860, height: 620)
        .handlesExternalEvents(matching: [])
    }
}
