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

    var body: some View {
        switch step {
        case .project:
            WizardColumn {
                IdentityBlock(draft: $draft)
                problemBox
            }
        case .board:
            WizardColumn {
                BoardBlock(draft: $draft, workspaces: linearWorkspaces, onSelect: onSelectInstallation)
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

// MARK: - Board

/// The Board step: a section per board. Linear's picks the Linear workspace (an App Installation in the
/// registry), then an existing Linear project or a team to create one in. Jira's is drawn, disabled and
/// marked Coming later: the step is shaped for more than one board without pretending to support one.
struct BoardBlock: View {
    @Binding var draft: AddProjectDraft
    let workspaces: LinearWorkspacesModel
    let onSelect: (String) -> Void
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Linear").font(.headline)
            workspaceBlock
            if draft.selectedLinearInstallation == nil {
                Text("Choose the Linear workspace first.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-linear-choose-workspace-first")
            } else {
                projectChoice
            }
            Divider()
            jiraBlock
        }
    }

    /// Jira, not yet supported: its two choices, disabled.
    private var jiraBlock: some View {
        WizardBlock(title: "Jira", footer: "Coming later. Yellowhammer supports Linear only today.") {
            RadioRow(title: "Use an existing Jira project", isSelected: false) {} // glossary:ignore GL001
            Divider().padding(.leading, 12)
            RadioRow(title: "Create a new Jira project", isSelected: false) {} // glossary:ignore GL001
        }
        .disabled(true)
        .opacity(0.5)
        .accessibilityIdentifier("setup-board-jira")
    }

    // MARK: Linear workspace

    @ViewBuilder private var workspaceBlock: some View {
        if workspaces.workspaces.isEmpty {
            WizardBlock(title: "Linear workspace", boxed: false) {
                Text("Yellowhammer connects to Linear through its own app, approved once by a workspace admin.")
                    .foregroundStyle(.secondary)
            }
            connectView(offersCancel: false)
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
                WizardOperatorIdentityBlock(model: operatorModel, workspaceLabel: workspaceLabel)
            }
            if isConnecting {
                connectView(offersCancel: true)
            } else {
                Button("Connect Another Linear Workspace\u{2026}") { isConnecting = true }
                    .accessibilityIdentifier("setup-linear-connect-another")
            }
        }
    }

    /// The install, boxed under its own heading. `offersCancel` closes it again before an install starts;
    /// once one runs, its own Cancel stops it.
    private func connectView(offersCancel: Bool) -> some View {
        WizardBlock(
            title: "Connect a Linear workspace",
            footer: "A workspace connected here stays connected if you cancel adding the Project."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LinearInstallationView(
                    model: workspaces.connectAnother,
                    offersReinstall: workspaces.connectAnother.phase.isInstalled,
                    arrangesInstallButtonsInRow: true,
                    onDismiss: offersCancel ? { isConnecting = false } : nil
                )
            }
            .padding(12)
        }
    }

    // MARK: Linear project

    /// The selected workspace's label, as its row in the workspace list names it.
    private var workspaceLabel: String {
        guard let name = draft.linearInstallationName else { return "" }
        return workspaces.workspaces.first { $0.name == name }.map(workspaces.label(for:)) ?? name
    }

    @ViewBuilder private var projectChoice: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linear project in \(workspaceLabel)") // glossary:ignore GL001
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                OptionCards {
                    OptionCard(
                        title: "Existing Linear project", // glossary:ignore GL001
                        detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                        isSelected: draft.linearChoice == .existing,
                        identifier: "setup-linear-choice-existing"
                    ) {
                        draft.linearChoice = .existing
                    }
                    OptionCard(
                        title: "New Linear project", // glossary:ignore GL001
                        detail: draft.displayName.isEmpty
                            ? "Yellowhammer creates one in a team you choose, named after the Project."
                            : "Yellowhammer creates \u{201c}\(draft.displayName)\u{201d} in a team you choose.",
                        isSelected: draft.linearChoice == .createInTeam,
                        identifier: "setup-linear-choice-create"
                    ) {
                        draft.linearChoice = .createInTeam
                    }
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
