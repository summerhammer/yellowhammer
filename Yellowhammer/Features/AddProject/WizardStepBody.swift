import Config
import Domain
import SwiftUI

/// One step's content for the Add Project wizard. Each step presents the user with one decision or set
/// of fields to complete.
struct WizardStepBody: View {
    let step: AddProjectDraft.Step
    @Binding var draft: AddProjectDraft
    /// The Linear step's workspaces list, and what selecting one does.
    let linearWorkspaces: LinearWorkspacesModel
    let onSelectInstallation: (String) -> Void

    var body: some View {
        switch step {
        case .project:
            WizardColumn {
                IdentityBlock(draft: $draft)
            }
        case .linearProject:
            WizardColumn {
                LinearBlock(draft: $draft, workspaces: linearWorkspaces, onSelect: onSelectInstallation)
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

/// The Linear step: which Linear workspace (an App Installation in the registry) the Project uses, then the
/// choice between an existing Linear project or creating a new one in a team.
struct LinearBlock: View {
    @Binding var draft: AddProjectDraft
    let workspaces: LinearWorkspacesModel
    let onSelect: (String) -> Void
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            workspaceBlock
            if draft.selectedLinearInstallation == nil {
                Text("Choose the Linear workspace first.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-linear-choose-workspace-first")
            } else {
                projectChoice
            }
            if draft.visited.contains(.linearProject) {
                let problems = draft.problems(in: .linearProject)
                if !problems.isEmpty {
                    WizardProblemList(problems: problems)
                }
            }
        }
    }

    // MARK: Linear workspace

    @ViewBuilder private var workspaceBlock: some View {
        if workspaces.workspaces.isEmpty {
            WizardBlock(title: "Linear workspace", boxed: false) {
                Text("Yellowhammer connects to Linear through its own app, approved once by a workspace admin.")
                    .foregroundStyle(.secondary)
                connectView
            }
        } else {
            WizardBlock(title: "Linear workspace") {
                ForEach(workspaces.workspaces) { workspace in
                    let label = workspaces.label(for: workspace)
                    RadioRow(
                        title: label,
                        subtitle: label == workspace.name ? nil : workspace.name,
                        note: workspace.operatorIdentity?.rawValue ?? "No Operator identity yet",
                        isSelected: draft.linearInstallationName == workspace.name,
                        identifier: "setup-linear-installation-\(workspace.name)"
                    ) {
                        onSelect(workspace.name)
                    }
                }
            }
            if let name = draft.linearInstallationName,
               let workspace = workspaces.workspaces.first(where: { $0.name == name }),
               workspace.operatorIdentity == nil,
               let operatorModel = workspaces.operatorModel(for: name) {
                OperatorIdentityRow(model: operatorModel, name: name, identifierPrefix: "setup-linear-operator")
            }
            if isConnecting {
                connectView
            } else {
                Button("Connect another Linear workspace\u{2026}") { isConnecting = true }
                    .accessibilityIdentifier("setup-linear-connect-another")
            }
        }
    }

    private var connectView: some View {
        VStack(alignment: .leading) {
            LinearInstallationView(
                model: workspaces.connectAnother, offersReinstall: workspaces.connectAnother.phase.isInstalled
            )
        }
    }

    // MARK: Linear project

    @ViewBuilder private var projectChoice: some View {
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
                if !draft.context.linearProjects.isEmpty {
                    WizardBlock(boxed: true) {
                        ForEach(draft.context.linearProjects, id: \.id) { project in
                            RadioRow(
                                title: project.name,
                                note: project.teamNames.joined(separator: ", "),
                                isSelected: draft.linearProjectID == project.id,
                                identifier: "setup-linear-project-\(project.id)"
                            ) {
                                draft.linearProjectID = project.id
                            }
                        }
                    }
                }
                WizardBlock(
                    footer: draft.context.linearProjects.isEmpty
                        ? "Copy it from the Linear project\u{2019}s URL or its settings." // glossary:ignore GL001
                        // glossary:ignore GL001
                        : "Not listed? Paste its id from the Linear project\u{2019}s URL or settings."
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
        }
    }
}

#Preview("Project") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.project, $draft).frame(width: 620, height: 560)
}

#Preview("Linear project") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.linearProject, $draft).frame(width: 620, height: 560)
}

#Preview("Repos") {
    @Previewable @State var draft = AddProjectDraft.preview
    WizardStepBody.preview(.repos, $draft).frame(width: 620, height: 560)
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
