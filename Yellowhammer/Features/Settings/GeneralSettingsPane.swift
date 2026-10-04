import SwiftUI

/// The machine-wide settings of the Settings window's General section: Orca ADE. The Linear workspaces
/// (Boards), Agent CLIs and the base Routing Table have panes of their own (P18.15, P18.16).
struct GeneralSettingsPane: View {
    var body: some View {
        SettingsPane(
            title: "General",
            explanation: "What this Mac shares with every Project: Orca ADE."
        ) {
            orcaADE
        }
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
