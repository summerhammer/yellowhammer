import AppKit
import Domain
import SwiftUI

/// The Settings window (Cmd+,): a sidebar with the machine-wide General section and the configured
/// Projects, and a toolbar with back, forward and the current section's name. It is a separate window
/// from the main window. A Project's Configuration is here; the steps after P18.13 fill in Recalibrate and
/// the machine-wide settings.
///
/// Where each piece of state lives:
/// - **The current section** is `history.current`. The sidebar's selection is derived from it, and a
///   selection records a visit, so back and forward cannot add entries.
/// - **The preselection** arrives in `SettingsRequest` when a gesture opens the window, from the key
///   main window's Project. After it is applied, this window's selection and the main window's are
///   independent.
/// - **The configuration** is read when the window appears and each time the app becomes active, the
///   same way the main window reads its snapshot. It reads no Journal.
struct SettingsWindow: View {
    static let windowID = "settings"

    @State private var history = SettingsHistory()
    @State private var configured: ConfiguredProjects?
    /// The last request token this window has applied. A new window starts at zero, so it applies the
    /// request that opened it.
    @State private var appliedRequest = 0
    @Environment(SettingsRequest.self) private var request

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
            SettingsSidebar(projects: configured?.entries ?? [], selection: selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Minimums sit on the columns, not on the split view (see `OverviewWindow`).
            detail
                .frame(minWidth: 380, minHeight: 320)
        }
        .navigationTitle(history.current.title(in: configured))
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
        .accessibilityIdentifier("settings-window")
        .onAppear(perform: applyRequest)
        .onChange(of: request.token) { applyRequest() }
        .task { await readWhileOpen() }
    }

    @ViewBuilder private var detail: some View {
        switch history.current {
        case .general:
            GeneralSettingsPane()
        case .refusedFiles:
            RefusedFilesPane(configured: configured)
        case let .project(id):
            if let configured {
                if configured.entry(for: id) != nil {
                    ProjectSettingsPane(project: id, onSaved: readConfiguration)
                } else {
                    // Its file may have been refused or removed since it was visited.
                    Text("\u{201C}\(id.rawValue)\u{201D} is not configured.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("settings-project-not-configured")
                }
            } else {
                ProgressView()
            }
        }
    }

    /// Reads the configuration again, so a saved name shows in the sidebar and the window's title.
    private func readConfiguration() {
        configured = ConfiguredProjects.load()
    }

    /// Visits the requested Project, once per request. A request naming no Project leaves the window
    /// where it is.
    private func applyRequest() {
        guard request.token != appliedRequest else { return }
        appliedRequest = request.token
        if let project = request.project { history.visit(.project(project)) }
    }

    /// Reads the configuration when the window opens, then each time the app becomes active. The loop is
    /// the window's own task, so it ends when the window closes.
    private func readWhileOpen() async {
        readConfiguration()
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            readConfiguration()
        }
    }
}
