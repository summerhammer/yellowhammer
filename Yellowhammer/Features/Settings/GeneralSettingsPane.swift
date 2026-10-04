import SwiftUI

/// The machine-wide settings of the Settings window's General section (P18.16, L3.1): the Linear
/// workspaces — one card per App Installation, and a way to connect another — and Orca ADE. Agent CLIs and
/// the base Routing Table have panes of their own (P18.15). The model is owned by `SettingsWindow`, so
/// moving to another sidebar row and back neither recreates it nor kills a running install.
struct GeneralSettingsPane: View {
    let model: LinearWorkspacesModel

    var body: some View {
        SettingsPane(
            title: "General",
            explanation: "What this Mac shares with every Project: the Linear workspaces Yellowhammer connects "
                + "to, and Orca ADE."
        ) {
            WizardBlock(
                title: "Linear workspaces",
                footer: "Yellowhammer connects to Linear through its own app, approved once by a "
                    + "workspace admin \u{2014} on this Mac, or remotely through a link you send them.",
                boxed: false
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if let loadFailure = model.loadFailure {
                        SettingsFailureText(text: loadFailure, identifier: "settings-linear-load-failure")
                    }
                    ForEach(model.workspaces) { workspace in
                        LinearWorkspaceRow(model: model, workspace: workspace)
                    }
                    if model.workspaces.isEmpty, model.loadFailure == nil {
                        Text("No Linear workspace is connected yet.")
                            .foregroundStyle(.secondary)
                    }
                    if !model.removalMessage.isEmpty {
                        WizardNote(text: model.removalMessage.joined(separator: "\n"))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-linear-removed")
                    }
                }
            }
            WizardBlock(
                title: model.workspaces.isEmpty ? "Connect a Linear workspace" : "Connect another Linear workspace"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    LinearInstallationView(
                        model: model.connectAnother, offersReinstall: true, arrangesInstallButtonsInRow: true
                    )
                }
                .padding(12)
            }
            orcaADE
        }
        .onAppear { model.refreshStatusOnFirstAppearance() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-general-pane")
    }

    private var orcaADE: some View {
        WizardBlock(
            title: "Orca ADE", // glossary:ignore GL001
            footer: "Yellowhammer has no Orca ADE setting of its own." // glossary:ignore GL001
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Orca ADE creates, places and cleans up every Worktree; Yellowhammer only records their paths.")
                Text(
                    "Setup resolves the orca executable on the PATH it writes into each Project\u{2019}s scheduled "
                        + "jobs, and warns when orca is not on it."
                )
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-orca-ade")
    }
}
