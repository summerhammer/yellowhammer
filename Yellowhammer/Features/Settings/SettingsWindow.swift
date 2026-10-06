import AppKit
import Domain
import SwiftUI

/// The Settings window (Cmd+,): a sidebar with the machine-wide General section and the configured
/// Projects, and a toolbar with back and forward; the current section's name is its pane's heading, and
/// every pane is drawn with the Add Project sheet's blocks (`SettingsPane`). It is a separate window
/// from the main window. A Project's Configuration, Recalibrate and the machine-wide settings
/// (General: Orca ADE; Boards: Board connections; Agent CLIs; the base Routing Table) are here.
///
/// Where each piece of state lives:
/// - **The current section** is `history.current`. The sidebar's selection is derived from it, and a
///   selection records a visit, so back and forward cannot add entries.
/// - **The preselection** arrives in `SettingsRequest` when a gesture opens the window, from the key
///   main window's Project. After it is applied, this window's selection and the main window's are
///   independent.
/// - **The Boards pane's model** (the Board connections list and the install, Operator identity and removal
///   models under it), which also supplies a Project entry's Linear workspace name, is this window's
///   `@State`, so another sidebar row and back neither recreates it nor kills a running install.
///   Closing the window terminates it: setup is not an Act, so no child of it survives the window.
/// - **The configuration** is read when the window appears and each time the app becomes active, the
///   same way the main window reads its snapshot. It reads no Journal.
struct SettingsWindow: View {
    static let windowID = "settings"

    @State private var history = SettingsHistory()
    @State private var configured: ConfiguredProjects?
    @State private var linearWorkspaces = LinearWorkspacesModel()
    /// The last request token this window has applied. A new window starts at zero, so it applies the
    /// request that opened it.
    @State private var appliedRequest = 0
    @Environment(SettingsRequest.self) private var request
    @Environment(ProjectListChanges.self) private var projectListChanges

    private var selection: Binding<SettingsSection?> {
        Binding(
            get: { history.current },
            set: { section in
                if let section { history.visit(section) }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                projects: configured?.entries ?? [],
                configured: configured,
                selection: selection,
                onProjectAdded: { id in
                    readConfiguration()
                    history.visit(.project(id))
                }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Minimums sit on the columns, not on the split view (see `OverviewWindow`).
            detail
                .frame(minWidth: 520, minHeight: 420)
        }
        // The window keeps its title (the Window menu and the window list name it by the section), but the
        // toolbar does not show it: each pane opens on its own heading, as an Add Project step does.
        .navigationTitle(history.current.title(in: configured))
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { history.back() } label: { Image(systemName: "chevron.backward") }
                    .help("Back")
                    .disabled(!history.canGoBack)
                    .accessibilityIdentifier("settings-back")
                Button { history.forward() } label: { Image(systemName: "chevron.forward") }
                    .help("Forward")
                    .disabled(!history.canGoForward)
                    .accessibilityIdentifier("settings-forward")
            }
        }
        .environment(\.showSettingsSection) { history.visit($0) }
        .accessibilityIdentifier("settings-window")
        .onAppear(perform: applyRequest)
        .onChange(of: request.token) { applyRequest() }
        // A Project added from the main window; a sheet finishing fires neither appear nor didBecomeActive.
        .onChange(of: projectListChanges.token) { readConfiguration() }
        .task { await readWhileOpen() }
        .onDisappear {
            linearWorkspaces.terminate()
        }
    }

    @ViewBuilder private var detail: some View {
        switch history.current {
        case .general:
            GeneralSettingsPane()
        case .boards:
            BoardsSettingsPane(model: linearWorkspaces)
        case .agentCLIs:
            AgentCLIsPane()
        case .baseRoutingTable:
            BaseRoutingTablePane()
        case .refusedFiles:
            RefusedFilesPane(configured: configured, onRemoved: refusedProjectRemoved)
        case let .project(id):
            if let configured {
                if let entry = configured.entry(for: id) {
                    // The label reads the model's statuses when the form's body calls it, so the form
                    // updates when `yh doctor` has been read.
                    let workspaces = linearWorkspaces
                    ProjectSettingsPane(
                        project: id, name: entry.name, onSaved: readConfiguration,
                        onRemoved: projectRemoved,
                        workspaceLabel: { name in
                            LinearInstallationStatus.label(
                                workspaceName: workspaces.statuses[name]?.workspaceName, localName: name
                            )
                        }
                    )
                    // The pane owns both tabs' models, so a different Project is a different pane.
                    .id(id)
                    .onAppear { workspaces.refreshStatusOnFirstAppearance() }
                } else {
                    // Its file may have been refused or removed since it was visited.
                    SettingsUnavailable(message: "\u{201C}\(id.rawValue)\u{201D} is not configured.")
                        .accessibilityIdentifier("settings-project-not-configured")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Reads the configuration again, so a saved name shows in the sidebar and the window's title.
    private func readConfiguration() {
        configured = ConfiguredProjects.load()
    }

    /// A Project was removed by `yh`: reads the configuration again so the sidebar drops it, leaves its pane
    /// for General, and tells the other windows, so the main window drops it too.
    private func projectRemoved() {
        readConfiguration()
        history.visit(.general)
        projectListChanges.record()
    }

    /// A Project was removed from the Refused Files pane: reads the configuration again so its card goes, and
    /// tells the other windows. The Operator stays on Refused Files, unlike `projectRemoved`.
    private func refusedProjectRemoved() {
        readConfiguration()
        projectListChanges.record()
    }

    /// Visits the requested Project or section, once per request. A request naming neither leaves the
    /// window where it is.
    private func applyRequest() {
        guard request.token != appliedRequest else { return }
        appliedRequest = request.token
        if let section = request.section {
            history.visit(section)
        } else if let project = request.project {
            history.visit(.project(project))
        }
    }

    /// Reads the configuration when the window opens, then each time the app becomes active. The loop is
    /// the window's own task, so it ends when the window closes.
    private func readWhileOpen() async {
        readConfiguration()
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            readConfiguration()
            linearWorkspaces.reloadIfClean()
        }
    }
}
