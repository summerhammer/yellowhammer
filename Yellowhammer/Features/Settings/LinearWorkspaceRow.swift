import Domain
import SwiftUI

/// One card of the Linear workspaces list: an App Installation's label, the Projects that use it, the
/// doctor's reading, its Operator identity, and the three things Settings does to it — re-connect, change
/// the Operator identity, remove. Every identifier is suffixed with the installation's local name.
struct LinearWorkspaceRow: View {
    let model: LinearWorkspacesModel
    let workspace: LinearWorkspacesModel.Workspace
    @State private var isConfirmingRemoval = false

    private var name: String { workspace.name }

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline) {
                header
                Spacer()
                removal
            }
            projects
            if let message = model.statuses[name]?.check.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-linear-status-\(name)")
            }
            if let lines = model.removalFailures[name] {
                SettingsFailureText(
                    text: lines.joined(separator: "\n"), identifier: "settings-linear-remove-failure-\(name)",
                    monospaced: true
                )
            }
            if let operatorModel = model.operatorModel(for: name) {
                Divider()
                OperatorIdentityRow(
                    model: operatorModel, name: name, identifierPrefix: "settings-linear-operator"
                )
            }
            if let reconnect = model.reconnectModel(for: name) {
                Divider()
                reconnectContent(reconnect)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-linear-row-\(name)")
    }

    @ViewBuilder private var header: some View {
        let label = model.label(for: workspace)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.headline)
                .accessibilityIdentifier("settings-linear-workspace-\(name)")
            if label != name {
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var projects: some View {
        Group {
            if workspace.projects.isEmpty {
                Text("No Project uses this workspace.")
            } else {
                Text("Used by \(workspace.projects.joined(separator: ", ")).")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings-linear-projects-\(name)")
    }

    @ViewBuilder private func reconnectContent(_ reconnect: LinearInstallationModel) -> some View {
        if reconnect.phase == .notInstalled {
            HStack {
                Button("Re-connect\u{2026}") { reconnect.startLinearInstall() }
                    .accessibilityIdentifier("settings-linear-reconnect-\(name)")
                Button("Request approval from an admin\u{2026}") { // glossary:ignore GL001
                    reconnect.startLinearInstall(remote: true)
                }
                .accessibilityIdentifier("settings-linear-reconnect-remote-\(name)")
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                LinearInstallationView(model: reconnect, offersReinstall: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-linear-reconnect-progress-\(name)")
        }
    }

    private var removal: some View {
        Button("Remove\u{2026}", role: .destructive) { isConfirmingRemoval = true }
            .buttonStyle(.borderless)
            .disabled(model.removing != nil)
            .accessibilityIdentifier("settings-linear-remove-\(name)")
            .confirmationDialog(
                "Remove the Linear workspace \(model.label(for: workspace))?", isPresented: $isConfirmingRemoval
            ) {
                Button("Remove", role: .destructive) { Task { await model.remove(name) } }
            } message: {
                Text(
                    "This deletes this Mac\u{2019}s entry and Keychain items for the workspace. Yellowhammer stays "
                        + "installed in that Linear workspace until a workspace admin removes it in Linear\u{2019}s "
                        + "settings."
                )
            }
    }
}
