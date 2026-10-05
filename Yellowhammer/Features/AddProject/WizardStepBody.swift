import Config
import Domain
import SwiftUI

/// One step's content for the Add Project wizard. Each step presents the user with one decision or set
/// of fields to complete.
struct WizardStepBody: View {
    let step: AddProjectDraft.Step
    @Binding var draft: AddProjectDraft
    /// The Board step's workspaces list, and what selecting one does.
    let linearWorkspaces: LinearWorkspacesModel
    let onSelectInstallation: (String) -> Void
    var onVerifyLinearProject: () -> Void = {}

    var body: some View {
        switch step {
        case .project:
            WizardColumn {
                IdentityBlock(draft: $draft)
                problemBox
            }
        case .board:
            WizardColumn {
                BoardBlock(
                    draft: $draft, workspaces: linearWorkspaces,
                    onSelect: onSelectInstallation, onVerify: onVerifyLinearProject
                )
                problemBox
            }
        case .repos:
            RepoStepView(draft: $draft) { problemBox }
        case .specSource:
            WizardColumn {
                SpecBlock(draft: $draft)
                problemBox
            }
        case .bounds:
            WizardColumn {
                BoundsBlock(draft: $draft)
                problemBox
            }
        case .jobs:
            Form {
                JobsSections(draft: $draft)
                if !revealedProblems.isEmpty {
                    Section { problemBox }
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The step's problems, once the Operator has left it; none on its first opening.
    private var revealedProblems: [String] {
        draft.revealsProblems(in: step) ? draft.problems(in: step) : []
    }

    /// Every step ends with the same box, drawn by the same rule.
    @ViewBuilder private var problemBox: some View {
        if !revealedProblems.isEmpty {
            WizardProblemBox(problems: revealedProblems)
        }
    }
}

// MARK: - Identity

/// The Project name and its permanent id, with a popover to edit the id.
struct IdentityBlock: View {
    @Binding var draft: AddProjectDraft
    @State private var isEditingID = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WizardBlock(title: "Project", footer: "You can rename the Project later in Settings.") {
                WizardBlockRow(label: "Name") {
                    TextField(
                        "Name",
                        text: Binding {
                            draft.name
                        } set: { draft.setName($0) },
                        prompt: Text("Acme")
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("setup-project-name")
                }
            }
            WizardBlock(
                title: "Project id",
                footer: "Made from the name. It names everything below and can\u{2019}t change once the "
                    + "Project is added."
            ) {
                HStack(spacing: 8) {
                    IdToken(id: draft.projectID)
                        .accessibilityIdentifier("setup-project-id")
                    PermanentBadge()
                    Spacer()
                    Button("Edit Id…") { isEditingID = true }
                        .accessibilityIdentifier("setup-edit-project-id")
                        .popover(isPresented: $isEditingID, arrowEdge: .bottom) { idEditor }
                }
                .padding(12)
                Divider()
                IdNamesList(id: draft.projectID)
            }
            identityMessages
        }
    }

    private var idEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project id").font(.headline)
            TextField(
                "Project id",
                text: Binding {
                    draft.projectID
                } set: { draft.setProjectID($0) }
            )
            .font(.body.monospaced())
            .labelsHidden()
            .accessibilityIdentifier("setup-project-id-field")
            Label(
                "Choose carefully: the id can\u{2019}t be changed after the Project is added.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.attention)
            HStack {
                Button("Use the Name") {
                    draft.idEdited = false
                    draft.setName(draft.name)
                }
                .disabled(!draft.idEdited)
                Spacer()
                Button("Done") { isEditingID = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder
    private var identityMessages: some View {
        if draft.isComplete(.project), draft.reusesJournal {
            WizardNote(
                text: "A removed Project left a Journal under \u{201c}\(draft.projectID)\u{201d}. "
                    + "This Project reopens it and continues its history."
            )
        }
    }
}

#Preview("Project") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.project, $draft).frame(width: 620, height: 560)
}

#Preview("Board") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.board, $draft).frame(width: 620, height: 560)
}

#Preview("Repos") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.repos, $draft).frame(width: 620, height: 560)
}

#Preview("Repos, one incomplete") {
    @Previewable @State var draft = {
        var draft = AddProjectDraft.preview
        draft.addRepo(path: "~/dev/acme/acme-tools")
        return draft
    }()
    WizardStepBody.preview(.repos, $draft).frame(width: 620, height: 640)
}

#Preview("Spec Source") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.specSource, $draft).frame(width: 620, height: 560)
}

#Preview("Bounds") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.bounds, $draft).frame(width: 620, height: 560)
}

#Preview("Scheduled jobs") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.jobs, $draft).frame(width: 620, height: 560)
}

extension LinearWorkspacesModel {
    /// A list read from a folder that holds no `config.toml`, so a preview never runs `yh`.
    @MainActor static var preview: LinearWorkspacesModel {
        LinearWorkspacesModel(directory: FileManager.default.temporaryDirectory.appending(path: "yellowhammer-preview"))
    }
}

extension WizardStepBody {
    /// A step for a preview: its workspaces list never runs `yh`, and selecting does nothing.
    static func preview(_ step: AddProjectDraft.Step, _ draft: Binding<AddProjectDraft>) -> WizardStepBody {
        WizardStepBody(
            step: step, draft: draft, linearWorkspaces: .preview, onSelectInstallation: { _ in }
        )
    }
}
