import SwiftUI

/// The machine-wide settings of the Settings window's General section (P18.16): the Linear App
/// Installation, the Operator identity and Orca ADE. Agent CLIs and the base Routing Table have panes of
/// their own (P18.15). Both models are owned by `SettingsWindow`, so moving to another sidebar row and back
/// neither recreates them nor kills a running install.
struct GeneralSettingsPane: View {
    let linearInstallation: LinearInstallationModel
    let operatorIdentity: OperatorIdentityModel

    var body: some View {
        Form {
            Section("Linear") { // glossary:ignore GL001
                Text(
                    "Yellowhammer connects to Linear through its own app, approved once by a " // glossary:ignore GL001
                        + "workspace admin — on this Mac, or remotely through a link you send them."
                )
                .foregroundStyle(.secondary)
                LinearInstallationView(model: linearInstallation, offersReinstall: true)
            }
            OperatorIdentitySection(model: operatorIdentity)
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
        .onChange(of: linearInstallation.phase.isInstalled) { _, isInstalled in
            // The Operator identity choice follows the install immediately.
            guard isInstalled else { return }
            operatorIdentity.reload()
            guard operatorIdentity.configured == nil else { return }
            Task { await operatorIdentity.fetchCandidates() }
        }
        .accessibilityIdentifier("settings-general-pane")
    }
}
