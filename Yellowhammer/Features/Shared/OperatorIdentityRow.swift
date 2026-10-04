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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Operator identity") // glossary:ignore GL001
                    if model.configured == nil {
                        Text(
                            "No Operator identity is configured; " // glossary:ignore GL001
                                + "Waiting on You issues are left unassigned."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(identifierPrefix)-\(name)")
                    }
                }
                Spacer(minLength: 12)
                configuredContent
                Button("Change Operator\u{2026}") { Task { await model.fetchCandidates() } } // glossary:ignore GL001
                    .disabled(model.isFetching || model.isSaving)
                    .accessibilityIdentifier("\(identifierPrefix)-choose-\(name)")
            }
            chooser
            if let failure = model.failure {
                SettingsFailureText(text: failure, identifier: "\(identifierPrefix)-failure-\(name)")
            }
        }
    }

    /// The configured identity as a fixed value: the member's name, and the Linear user id under it.
    @ViewBuilder private var configuredContent: some View {
        if let configured = model.configured {
            VStack(alignment: .trailing, spacing: 2) {
                if let candidate = model.configuredCandidate {
                    Text("\(candidate.displayName) (\(candidate.name))")
                }
                Text(configured.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifierPrefix)-\(name)")
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        if model.isFetching {
            ProgressView().controlSize(.small)
        }
        if !model.fetchFailure.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(OperatorIdentityModel.fetchFailureSummary)
                    .foregroundStyle(.secondary)
                SettingsFailureText(
                    text: model.fetchFailure.joined(separator: "\n"),
                    identifier: "\(identifierPrefix)-fetch-failure-\(name)", monospaced: true
                )
            }
            .font(.callout)
        }
        if !model.candidates.isEmpty {
            HStack(spacing: 8) {
                Picker("Operator identity", selection: $model.selection) { // glossary:ignore GL001
                    Text("Choose one").tag(String?.none)
                    ForEach(model.candidates, id: \.id) { candidate in
                        Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("\(identifierPrefix)-picker-\(name)")
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                    .accessibilityIdentifier("\(identifierPrefix)-revert-\(name)")
                Button("Save") { Task { await model.save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty || model.selection == nil || model.isSaving)
                    .accessibilityIdentifier("\(identifierPrefix)-save-\(name)")
            }
        }
    }
}
