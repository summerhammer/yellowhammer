import Config
import Domain
import SwiftUI

/// One step's content for the Add Project wizard. Each step presents the user with one decision or set
/// of fields to complete.
struct WizardStepBody: View {
    let step: AddProjectDraft.Step
    @Binding var draft: AddProjectDraft

    var body: some View {
        switch step {
        case .project:
            WizardColumn {
                IdentityBlock(draft: $draft)
            }
        case .linearProject:
            WizardColumn {
                LinearBlock(draft: $draft)
            }
        case .repos:
            RepoStepView(draft: $draft)
        case .specSource:
            WizardColumn {
                SpecBlock(draft: $draft)
            }
        case .bounds:
            WizardColumn {
                BoundsBlock(draft: $draft)
            }
        case .jobs:
            Form {
                JobsSections(draft: $draft)
            }
            .formStyle(.grouped)
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
        let problems = draft.problems(in: .project)
        if !problems.isEmpty, !draft.name.isEmpty || draft.idEdited {
            WizardProblemList(problems: problems)
        } else if draft.reusesJournal {
            WizardNote(
                text: "A removed Project left a Journal under \u{201c}\(draft.projectID)\u{201d}. "
                    + "This Project reopens it and continues its history."
            )
        }
    }
}

// MARK: - Linear project

/// The choice between an existing Linear project or creating a new one in a team.
struct LinearBlock: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OptionCards {
                OptionCard(
                    title: "Use an existing one",
                    detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                    isSelected: draft.linearChoice == .existing,
                    identifier: "setup-linear-choice-existing"
                ) {
                    draft.linearChoice = .existing
                }
                OptionCard(
                    title: "Create a new one",
                    detail: draft.displayName.isEmpty
                        ? "Yellowhammer creates one in a team you choose, named after the Project."
                        : "Yellowhammer creates \u{201c}\(draft.displayName)\u{201d} in a team you choose.",
                    isSelected: draft.linearChoice == .createInTeam,
                    identifier: "setup-linear-choice-create"
                ) {
                    draft.linearChoice = .createInTeam
                }
            }
            switch draft.linearChoice {
            case .existing:
                WizardBlock(
                    footer: "Copy it from the Linear project\u{2019}s URL or its settings." // glossary:ignore GL001
                ) {
                    WizardBlockRow(label: "Linear project id") { // glossary:ignore GL001
                        TextField(
                            "Linear project id",
                            text: $draft.linearProjectID,
                            prompt: Text("Paste the id from Linear")
                        )
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260)
                        .accessibilityIdentifier("setup-linear-project-id")
                    }
                }
            case .createInTeam:
                WizardBlock(boxed: true) {
                    if draft.context.teams.isEmpty {
                        Text(
                            "No teams yet. Yellowhammer reads them from Linear once it is installed."
                        )
                        .foregroundStyle(.secondary)
                        .padding(12)
                    } else {
                        ForEach(draft.context.teams, id: \.id) { team in
                            RadioRow(
                                title: team.name,
                                note: team.key,
                                isSelected: draft.teamKey == team.key,
                                identifier: "setup-team-\(team.key)"
                            ) {
                                draft.teamKey = team.key
                            }
                        }
                    }
                }
            }
            if draft.visited.contains(.linearProject) {
                let problems = draft.problems(in: .linearProject)
                if !problems.isEmpty {
                    WizardProblemList(problems: problems)
                }
            }
        }
    }
}

#Preview("Project") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .project, draft: $draft).frame(width: 620, height: 560)
}

#Preview("Linear project") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .linearProject, draft: $draft).frame(width: 620, height: 560)
}

#Preview("Repos") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .repos, draft: $draft).frame(width: 620, height: 560)
}

#Preview("Spec Source") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .specSource, draft: $draft).frame(width: 620, height: 560)
}

#Preview("Bounds") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .bounds, draft: $draft).frame(width: 620, height: 560)
}

#Preview("Scheduled jobs") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody(step: .jobs, draft: $draft).frame(width: 620, height: 560)
}
