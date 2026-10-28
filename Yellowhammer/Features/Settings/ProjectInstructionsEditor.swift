import Domain
import SwiftUI

/// A Project's instructions: one plain-text editor with its own Save, Discard, Preview, Compare and Reset,
/// independent of the Configuration form's footer. The text is stored by ``ProjectInstructionsModel`` and
/// never goes into the Project's TOML.
struct ProjectInstructionsEditor: View {
    @Bindable var model: ProjectInstructionsModel
    let name: String
    @State private var sheet: Sheet?
    @State private var isConfirmingReset = false

    private enum Sheet: String, Identifiable {
        case preview
        case compare
        var id: String { rawValue }
    }

    var body: some View {
        WizardBlock(title: "Project instructions") {
            VStack(alignment: .leading, spacing: 12) {
                explanation
                if !model.defaultChanges.isEmpty, let revision = model.revision {
                    ProjectInstructionsReviewBanner(model: model, revision: revision)
                }
                editor
                counter
                notices
                controls
            }
            .padding(12)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .preview: ProjectInstructionsPreviewSheet(text: model.draft, mode: .preview)
            case .compare: ProjectInstructionsPreviewSheet(text: model.draft, mode: .compare)
            }
        }
        .confirmationDialog(
            "Reset the Project instructions for \(name)?", isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { model.reset() }
                .accessibilityIdentifier("settings-project-instructions-reset-confirm") // glossary:ignore GL001
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Future dispatches go back to the shipped prompts. Prompt records already kept are not "
                    + "deleted, and neither is the context of sessions that resume."
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-project-instructions") // glossary:ignore GL001
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Operator-supplied guidance added to the selection, breakdown, architect, worker, reviewer and "
                    + "verifier prompts for this Project, on every Route. It never reaches diagnostic probes or "
                    + "Route Pre-flight."
            )
            Text(
                "It cannot remove or replace Yellowhammer\u{2019}s contract, schema, task facts, boundaries or "
                    + "required Checks, and it cannot change a Work Card\u{2019}s Definition of Done, which stays "
                    + "on the board. Prose that conflicts with the contract may still confuse a model, and "
                    + "saving is not evidence that an agent will obey. Empty means the shipped behaviour."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("settings-project-instructions-explanation") // glossary:ignore GL001
    }

    private var editor: some View {
        TextEditor(text: $model.draft)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 160, maxHeight: 320)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
            .accessibilityLabel("Project instructions")
            .accessibilityIdentifier("settings-project-instructions-editor") // glossary:ignore GL001
    }

    private var counter: some View {
        let limit = ProjectInstructions.maximumByteCount.formatted(.number.locale(Locale(identifier: "en_US")))
        let used = model.byteCount.formatted(.number.locale(Locale(identifier: "en_US")))
        return Text("\(used) of \(limit) bytes")
            .font(.caption.monospacedDigit())
            .foregroundStyle(model.isOverLimit ? AnyShapeStyle(.error) : AnyShapeStyle(.secondary))
            .accessibilityIdentifier("settings-project-instructions-counter") // glossary:ignore GL001
    }

    @ViewBuilder private var notices: some View {
        if let cause = model.unavailableCause {
            SettingsFailureText(
                text: "The saved Project instructions cannot be read: \(cause). Reset them to start again.",
                identifier: "settings-project-instructions-unreadable" // glossary:ignore GL001
            )
        }
        if let failure = model.failure {
            SettingsFailureText(
                text: failure, identifier: "settings-project-instructions-failure" // glossary:ignore GL001
            )
        }
        if let conflict = model.conflict {
            conflictNotice(conflict)
        }
        if let confirmation = model.confirmation {
            Text(confirmationText(confirmation))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-project-instructions-confirmation") // glossary:ignore GL001
        }
    }

    private func conflictNotice(_ current: ProjectInstructionsRead) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsFailureText(
                text: "The saved Project instructions changed since you opened them"
                    + (current == .absent ? " (they were cleared)" : "")
                    + ". Reload to discard your draft and read the newer ones, or replace them with your draft.",
                identifier: "settings-project-instructions-conflict" // glossary:ignore GL001
            )
            HStack(spacing: 8) {
                Button("Reload") { model.reload() }
                    .accessibilityIdentifier("settings-project-instructions-reload") // glossary:ignore GL001
                Button("Replace") { model.replace() }
                    .accessibilityIdentifier("settings-project-instructions-replace") // glossary:ignore GL001
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button("Preview") { sheet = .preview }
                .accessibilityIdentifier("settings-project-instructions-preview") // glossary:ignore GL001
            Button("Compare") { sheet = .compare }
                .accessibilityIdentifier("settings-project-instructions-compare") // glossary:ignore GL001
            // Stays enabled when the saved text cannot be read: Reset is how that is recovered from.
            Button("Reset\u{2026}", role: .destructive) { isConfirmingReset = true }
                .accessibilityIdentifier("settings-project-instructions-reset") // glossary:ignore GL001
            Spacer(minLength: 12)
            Button("Discard") { model.discard() }
                .disabled(!model.isDirty)
                .accessibilityIdentifier("settings-project-instructions-discard") // glossary:ignore GL001
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
                .accessibilityIdentifier("settings-project-instructions-save") // glossary:ignore GL001
        }
    }

    private func confirmationText(_ confirmation: ProjectInstructionsModel.Confirmation) -> String {
        switch confirmation {
        case .saved(let id):
            "Saved Project instructions for \(name), revision \(ProjectInstructionsModel.shortID(id)). "
                + "Dispatches from now on use them."
        case .cleared:
            "Cleared the Project instructions for \(name). Dispatches from now on use the shipped prompts."
        case .reset:
            "Reset the Project instructions for \(name). Prompt records already kept are not deleted."
        case .reviewed(let id):
            "Marked the Project instructions for \(name) reviewed, revision \(ProjectInstructionsModel.shortID(id))."
        }
    }
}

/// The persistent *default changed — review instructions* warning: the families whose default moved, the
/// old default as unavailable (it is never reconstructed), the new default, and the saved text. It clears
/// only when the Operator marks it reviewed.
struct ProjectInstructionsReviewBanner: View {
    let model: ProjectInstructionsModel
    let revision: ProjectInstructionsRevision
    @State private var shownDefault: PromptCatalogEntry?

    var body: some View {
        let changes = model.defaultChanges
        VStack(alignment: .leading, spacing: 10) {
            Label("Default changed \u{2014} review instructions", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.warning)
            Text(
                "The shipped prompt changed for \(families(changes)) since these instructions were last reviewed. "
                    + "The text below stays active with the current defaults until you mark it reviewed."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(changes, id: \.family) { change in
                changeRow(change)
            }
            Text("Saved text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(revision.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.background, in: .rect(cornerRadius: 8))
            .accessibilityIdentifier("settings-project-instructions-review-text") // glossary:ignore GL001
            HStack {
                Spacer()
                Button("Mark reviewed") { model.markReviewed() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings-project-instructions-mark-reviewed") // glossary:ignore GL001
            }
        }
        .padding(12)
        .background(.warning.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.warning.opacity(0.35), lineWidth: 1))
        .sheet(item: $shownDefault) { PromptTemplateSheet(entry: $0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-project-instructions-review-banner") // glossary:ignore GL001
    }

    private func showDefaultIdentifier(_ family: PromptFamily) -> String {
        "settings-project-instructions-show-default-\(family.rawValue)" // glossary:ignore GL001
    }

    private func families(_ changes: [ProjectInstructionsDefaultChange]) -> String {
        changes.map { title(of: $0.family) }.formatted(.list(type: .and))
    }

    private func title(of family: PromptFamily) -> String {
        PromptCatalog.entry(for: family)?.title ?? family.rawValue
    }

    private func changeRow(_ change: ProjectInstructionsDefaultChange) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: change.family)).font(.body.weight(.medium))
                Text(
                    "Reviewed default: \(change.reviewedVersion.map { "version \($0)" } ?? "not recorded") "
                        + "\u{2014} not retained, unavailable"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Current default: version \(change.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show new default") { shownDefault = PromptCatalog.entry(for: change.family) }
                .accessibilityIdentifier(showDefaultIdentifier(change.family))
        }
    }
}
