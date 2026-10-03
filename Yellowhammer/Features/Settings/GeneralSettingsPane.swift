import SwiftUI

/// The machine-wide settings of the Settings window's General section (P18.16, L3.1): the Linear
/// workspaces — one row per App Installation, and a way to connect another — and Orca ADE. Agent CLIs and
/// the base Routing Table have panes of their own (P18.15). The model is owned by `SettingsWindow`, so
/// moving to another sidebar row and back neither recreates it nor kills a running install.
struct GeneralSettingsPane: View {
    let model: LinearWorkspacesModel

    var body: some View {
        Form {
            Section("Linear workspaces") {
                Text(
                    "Yellowhammer connects to Linear through its own app, approved once by a " // glossary:ignore GL001
                        + "workspace admin — on this Mac, or remotely through a link you send them."
                )
                .foregroundStyle(.secondary)
                if let loadFailure = model.loadFailure {
                    Text(loadFailure)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-linear-load-failure")
                }
                ForEach(model.workspaces) { workspace in
                    LinearWorkspaceRow(model: model, workspace: workspace)
                }
                if !model.removalMessage.isEmpty {
                    Text(model.removalMessage.joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-linear-removed")
                }
            }
            Section(model.workspaces.isEmpty ? "Connect a Linear workspace" : "Connect another Linear workspace") {
                LinearInstallationView(model: model.connectAnother, offersReinstall: true)
            }
            Section("Orca ADE") { // glossary:ignore GL001
                Text("Orca ADE creates, places and cleans up every Worktree; Yellowhammer only records their paths.")
                    .foregroundStyle(.secondary)
                Text(
                    "Setup resolves the orca executable on the PATH it writes into each Project\u{2019}s scheduled "
                        + "jobs, and warns when orca is not on it. Yellowhammer has no Orca ADE setting of its own."
                )
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings-orca-ade")
        }
        .formStyle(.grouped)
        .onAppear { model.refreshStatusOnFirstAppearance() }
        .accessibilityIdentifier("settings-general-pane")
    }
}
