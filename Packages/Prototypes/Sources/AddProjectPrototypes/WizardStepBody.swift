#if DEBUG
import SwiftUI

// Hub4's first two steps. The Project id is a locked token marked Permanent; the Linear project is
// two option cards — an existing one or a new one — over the matching list.

// MARK: - Identity

struct IdentityBlock: View {
    @Binding var draft: AddProjectDraft
    @State private var isEditingID = false
    @Environment(\.wizardBlocksShowProblems) private var showsProblems

    private var nameBinding: Binding<String> {
        Binding { draft.name } set: { draft.setName($0) }
    }

    private var idBinding: Binding<String> {
        Binding { draft.projectID } set: { draft.setProjectID($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WizardBlock(title: "Project", footer: "You can rename the Project later in Settings.") {
                WizardBlockRow(label: "Name") {
                    TextField("Name", text: nameBinding, prompt: Text("Acme"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260)
                }
            }
            WizardBlock(
                title: "Project id",
                footer: "Made from the name. It names everything below and can\u{2019}t change once the "
                    + "Project is added."
            ) {
                HStack(spacing: 8) {
                    IdToken(id: draft.projectID)
                    PermanentBadge()
                    Spacer()
                    Button("Edit Id…") { isEditingID = true }
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
            TextField("Project id", text: idBinding).font(.body.monospaced()).labelsHidden()
            Label("Choose carefully: the id can\u{2019}t be changed after the Project is added.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(WizardTheme.attention)
            HStack {
                Button("Use the Name") { draft.idEdited = false; draft.setName(draft.name) }
                    .disabled(!draft.idEdited)
                Spacer()
                Button("Done") { isEditingID = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    @ViewBuilder private var identityMessages: some View {
        let problems = draft.problems(in: .project).filter { $0.contains("id") || $0.contains("exists") }
        if showsProblems, !problems.isEmpty, !draft.name.isEmpty || draft.idEdited {
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

struct LinearBlock: View { // glossary:ignore GL001
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OptionCards {
                OptionCard(
                    title: "Use an existing one",
                    detail: "Pick a Linear project you already plan in.", // glossary:ignore GL001
                    isSelected: draft.linearChoice == .existing
                ) { draft.linearChoice = .existing }
                OptionCard(
                    title: "Create a new one",
                    detail: draft.displayName.isEmpty
                        ? "Yellowhammer creates one in a team you choose, named after the Project."
                        : "Yellowhammer creates \u{201c}\(draft.displayName)\u{201d} in a team you choose.",
                    isSelected: draft.linearChoice == .createInTeam
                ) { draft.linearChoice = .createInTeam }
            }
            VStack(spacing: 0) {
                switch draft.linearChoice {
                case .existing:
                    ForEach(AddProjectFixtures.linearProjects) { project in
                        RadioRow(
                            title: project.name, note: project.teamName,
                            isSelected: draft.linearProjectID == project.id
                        ) { draft.linearProjectID = project.id }
                    }
                case .createInTeam:
                    ForEach(AddProjectFixtures.teams) { team in
                        RadioRow(title: team.name, note: team.key, isSelected: draft.teamKey == team.key) {
                            draft.teamKey = team.key
                        }
                    }
                }
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
        }
    }
}
#endif
