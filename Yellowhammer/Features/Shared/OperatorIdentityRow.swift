import Domain
import SwiftUI

/// The Operator identity part of a Linear workspace row, in Settings and in the Add Project wizard: the configured identity, and a picker over the
/// workspace's Operator candidates, which `yh` reads from Linear when the Operator asks.
struct OperatorIdentityRow: View {
    @Bindable var model: OperatorIdentityModel
    let name: String
    /// Prefixes every accessibility identifier: `<prefix>-<name>`, `<prefix>-choose-<name>`, and so on.
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            configuredContent
            chooser
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifierPrefix)-failure-\(name)")
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
            .accessibilityIdentifier("\(identifierPrefix)-\(name)")
        } else {
            Text(
                "No Operator identity is configured; " // glossary:ignore GL001
                    + "Waiting on You issues are left unassigned."
            )
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("\(identifierPrefix)-\(name)")
        }
    }

    @ViewBuilder private var chooser: some View {
        Button("Change Operator\u{2026}") { Task { await model.fetchCandidates() } } // glossary:ignore GL001
            .disabled(model.isFetching || model.isSaving)
            .accessibilityIdentifier("\(identifierPrefix)-choose-\(name)")
        if model.isFetching {
            ProgressView()
        }
        if !model.fetchFailure.isEmpty {
            Text(OperatorIdentityModel.fetchFailureSummary)
                .foregroundStyle(.secondary)
            Text(model.fetchFailure.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("\(identifierPrefix)-fetch-failure-\(name)")
        }
        if !model.candidates.isEmpty {
            Picker("Operator identity", selection: $model.selection) { // glossary:ignore GL001
                Text("Choose one").tag(String?.none)
                ForEach(model.candidates, id: \.id) { candidate in
                    Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                }
            }
            .accessibilityIdentifier("\(identifierPrefix)-picker-\(name)")
            HStack {
                Button("Save") { Task { await model.save() } }
                    .disabled(!model.isDirty || model.selection == nil || model.isSaving)
                    .accessibilityIdentifier("\(identifierPrefix)-save-\(name)")
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                    .accessibilityIdentifier("\(identifierPrefix)-revert-\(name)")
            }
        }
    }
}
