import SwiftUI

/// The board integrations of the Settings window's Boards section (P18.16, L3.1): the Linear workspaces —
/// one card per App Installation, and a way to connect another. The model is owned by `SettingsWindow`, so
/// moving to another sidebar row and back neither recreates it nor kills a running install.
struct BoardsSettingsPane: View {
    let model: LinearWorkspacesModel

    var body: some View {
        SettingsPane(
            title: "Boards",
            explanation: "The boards this Mac\u{2019}s Projects are driven from: the Linear workspaces Yellowhammer "
                + "connects to."
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
        }
        .onAppear { model.refreshStatusOnFirstAppearance() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-boards-pane")
    }
}
