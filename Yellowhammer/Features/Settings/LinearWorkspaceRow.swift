import Domain
import SwiftUI

/// One card of the Linear workspaces list: an App Installation's label, the Projects that use it, the
/// doctor's reading, its Operator identity, and the three things Settings does to it — re-connect, change
/// the Operator identity, remove. Every identifier is suffixed with the installation's local name.
struct LinearWorkspaceRow: View {
    let model: LinearWorkspacesModel
    let workspace: LinearWorkspacesModel.Workspace
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingOrphanRemoval = false

    private var name: String { workspace.name }

    var body: some View {
        SettingsCard {
            HStack(alignment: .firstTextBaseline) {
                header
                Spacer()
                removal
            }
            projects
            if let block = model.removalBlock(for: workspace) {
                Text(block)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-linear-remove-blocked-\(name)")
            }
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

    /// *Remove…*, disabled while Projects use the installation or a Project file failed to decode (the
    /// reason is shown under the header); beside it, *Remove anyway…* when the live check found the
    /// authorization refused (OQ121 item 11).
    private var removal: some View {
        HStack(spacing: 12) {
            if model.offersOrphanRemoval(for: workspace) {
                orphanRemoval
            }
            plainRemoval
        }
    }

    private var plainRemoval: some View {
        Button("Remove\u{2026}", role: .destructive) { isConfirmingRemoval = true }
            .buttonStyle(.borderless)
            .disabled(model.removing != nil || model.removalBlock(for: workspace) != nil)
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

    private var orphanRemoval: some View {
        Button("Remove Anyway\u{2026}", role: .destructive) { isConfirmingOrphanRemoval = true }
            .buttonStyle(.borderless)
            .disabled(model.removing != nil)
            .accessibilityIdentifier("settings-linear-remove-anyway-\(name)")
            .confirmationDialog(
                "Remove \(name) anyway?", isPresented: $isConfirmingOrphanRemoval
            ) {
                Button("Remove Anyway", role: .destructive) {
                    Task { await model.remove(name, orphanProjects: true) }
                }
            } message: {
                Text(orphanRemovalMessage)
            }
    }

    /// What OQ121 items 12 and 14 list: the installation by local name (the workspace name cannot be read
    /// while Linear refuses it), the Projects left refused, the next step for each, that the app stays
    /// installed in Linear, and the undo under this exact local name. `yh`'s report repeats it afterwards.
    private var orphanRemovalMessage: String {
        let projects = workspace.projects
        let commands = projects.map { "yh project remove \($0)" } // glossary:ignore GL001
        return [
            "Linear refuses the installation \(name), so this deletes this Mac\u{2019}s entry and Keychain "
                + "items for it while Projects still use it.",
            "These Projects will be refused at load until they are removed or the workspace is re-connected: "
                + projects.joined(separator: ", ") + ".",
            "Next, remove each of them: " + commands.joined(separator: "; ") + ".",
            "Yellowhammer stays installed in that Linear workspace until a workspace admin removes it in "
                + "Linear\u{2019}s settings.",
            "To undo, re-connect the same workspace under this exact local name: "
                + "yh setup --installation-name \(name)."
        ].joined(separator: "\n\n")
    }
}
