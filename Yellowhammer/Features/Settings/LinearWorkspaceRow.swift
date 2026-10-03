import Domain
import SwiftUI

/// One row of the Linear workspaces list: an App Installation's label, the Projects that use it, the
/// doctor's reading, its Operator identity, and the three things Settings does to it — re-connect, change
/// the Operator identity, remove. Every identifier is suffixed with the installation's local name.
struct LinearWorkspaceRow: View {
    let model: LinearWorkspacesModel
    let workspace: LinearWorkspacesModel.Workspace
    @State private var isConfirmingRemoval = false

    private var name: String { workspace.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            projects
            if let message = model.statuses[name]?.check.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-linear-status-\(name)")
            }
            if let operatorModel = model.operatorModel(for: name) {
                OperatorIdentityRow(model: operatorModel, name: name)
            }
            if let reconnect = model.reconnectModel(for: name) {
                reconnectContent(reconnect)
            }
            removal
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-linear-row-\(name)")
    }

    @ViewBuilder private var header: some View {
        let label = model.label(for: workspace)
        VStack(alignment: .leading) {
            Text(label)
                .font(.headline)
                .accessibilityIdentifier("settings-linear-workspace-\(name)")
            if label != name {
                Text(name)
                    .font(.system(.footnote, design: .monospaced))
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
            VStack(alignment: .leading) {
                LinearInstallationView(model: reconnect, offersReinstall: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-linear-reconnect-progress-\(name)")
        }
    }

    @ViewBuilder private var removal: some View {
        Button("Remove\u{2026}", role: .destructive) { isConfirmingRemoval = true }
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
        if let lines = model.removalFailures[name] {
            Text(lines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings-linear-remove-failure-\(name)")
        }
    }
}

/// The Operator identity part of a Linear workspace row: the configured identity, and a picker over the
/// workspace's Operator candidates, which `yh` reads from Linear when the Operator asks.
private struct OperatorIdentityRow: View {
    @Bindable var model: OperatorIdentityModel
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            configuredContent
            chooser
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-linear-operator-failure-\(name)")
            }
        }
    }

    @ViewBuilder private var configuredContent: some View {
        if let configured = model.configured {
            LabeledContent("Operator identity") { // glossary:ignore GL001
                VStack(alignment: .trailing) {
                    if let candidate = model.configuredCandidate {
                        Text("\(candidate.displayName) (\(candidate.name))")
                    }
                    Text(configured.rawValue)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("settings-linear-operator-\(name)")
        } else {
            Text(
                "No Operator identity is configured; " // glossary:ignore GL001
                    + "Waiting on You issues are left unassigned."
            )
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-linear-operator-\(name)")
        }
    }

    @ViewBuilder private var chooser: some View {
        Button("Change Operator\u{2026}") { Task { await model.fetchCandidates() } } // glossary:ignore GL001
            .disabled(model.isFetching || model.isSaving)
            .accessibilityIdentifier("settings-linear-operator-choose-\(name)")
        if model.isFetching {
            ProgressView()
        }
        if !model.fetchFailure.isEmpty {
            Text(OperatorIdentityModel.fetchFailureSummary)
                .foregroundStyle(.secondary)
            Text(model.fetchFailure.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("settings-linear-operator-fetch-failure-\(name)")
        }
        if !model.candidates.isEmpty {
            Picker("Operator identity", selection: $model.selection) { // glossary:ignore GL001
                Text("Choose one").tag(String?.none)
                ForEach(model.candidates, id: \.id) { candidate in
                    Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("settings-linear-operator-picker-\(name)")
            HStack {
                Button("Save") { Task { await model.save() } }
                    .disabled(!model.isDirty || model.selection == nil || model.isSaving)
                    .accessibilityIdentifier("settings-linear-operator-save-\(name)")
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                    .accessibilityIdentifier("settings-linear-operator-revert-\(name)")
            }
        }
    }
}
