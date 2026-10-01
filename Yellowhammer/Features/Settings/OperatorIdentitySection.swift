import Domain
import SwiftUI

/// The Operator identity section of ``GeneralSettingsPane``: the configured identity, and a picker over the
/// workspace's Operator candidates, which `yh` reads from Linear when the Operator asks.
struct OperatorIdentitySection: View {
    @Bindable var model: OperatorIdentityModel
    @Environment(\.addProject) private var addProject

    var body: some View {
        Section("Operator identity") { // glossary:ignore GL001
            if model.configMissing {
                Text("`config.toml` does not exist yet.")
                    .foregroundStyle(.secondary)
                Button("Add a Project\u{2026}") { addProject() }
                    .accessibilityIdentifier("open-setup")
            } else if let loadFailure = model.loadFailure {
                Text(loadFailure)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-operator-load-failure")
            } else {
                configuredContent
                chooser
                if let failure = model.failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-operator-failure")
                }
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
            .accessibilityIdentifier("settings-operator-configured")
        } else {
            Text(
                "No Operator identity is configured; " // glossary:ignore GL001
                    + "Waiting on You issues are left unassigned."
            )
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-operator-none")
        }
        Text("Waiting on You issues are assigned to this person.") // glossary:ignore GL001
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var chooser: some View {
        Button("Choose…") { Task { await model.fetchCandidates() } }
            .disabled(model.isFetching)
            .accessibilityIdentifier("settings-operator-choose")
        if model.isFetching {
            ProgressView()
        }
        if !model.fetchFailure.isEmpty {
            Text(OperatorIdentityModel.fetchFailureSummary)
                .foregroundStyle(.secondary)
            Text(model.fetchFailure.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("settings-operator-fetch-failure")
        }
        if !model.candidates.isEmpty {
            Picker("Operator identity", selection: $model.selection) { // glossary:ignore GL001
                Text("Choose one").tag(String?.none)
                ForEach(model.candidates, id: \.id) { candidate in
                    Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("settings-operator-picker")
            HStack {
                Button("Save") { model.save() }
                    .disabled(!model.isDirty || model.selection == nil)
                    .accessibilityIdentifier("settings-operator-save")
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("settings-operator-revert")
            }
        }
    }
}
