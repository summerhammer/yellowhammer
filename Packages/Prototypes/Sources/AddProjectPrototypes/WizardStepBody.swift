#if DEBUG
import SwiftUI

// Round two's step content. Each of the four open questions — the permanent id, the Linear project
// choice, the specification source, and what a Bound means — has interchangeable treatments, so a
// variant picks one of each and the Gallery compares them in place.

/// How the id is shown and committed.
enum IdentityStyle {
    /// The name is a field; the id follows it and reads as a locked token marked Permanent, with what
    /// it names listed underneath. Editing it is a deliberate popover.
    case lockedToken
    /// Name and id are fields until the Operator confirms the id in a dialog; then the id locks.
    case confirmable
    /// A large name field leads; the id sits under it as a small locked token.
    case nameFirst
    /// The variant handles the id elsewhere (a gate before the hub).
    case hidden
}

enum LinearStyle {
    /// Two option cards — existing or new — then the matching picker.
    case choiceCards
    /// One list grouped by team: every existing Linear project, and a "new" row per team.
    case unifiedList
}

enum SpecStyle {
    /// Two option cards — a shared folder or one of this Project's Repos — then the candidates.
    case optionCards
    /// One list of every candidate, grouped by kind.
    case candidateList
}

enum BoundsPresentation {
    /// Grouped by what happens when one fires; a title, an explanation, the value with its unit.
    case explained
    /// One sentence per Bound with the value in bold and a stepper beside it.
    case sentences
}

struct WizardComponents {
    var identity: IdentityStyle = .lockedToken
    var linear: LinearStyle = .choiceCards
    var spec: SpecStyle = .optionCards
    var bounds: BoundsPresentation = .explained
}

/// One step's content in round two. Repos are always cards — the one Repo list that worked.
struct WizardStepBody: View {
    let step: WizardStep
    @Binding var draft: AddProjectDraft
    var components = WizardComponents()
    var maxWidth: CGFloat = .infinity

    var body: some View {
        switch step {
        case .project:
            WizardColumn(maxWidth: maxWidth) {
                IdentityBlock(draft: $draft, style: components.identity)
                LinearBlock(draft: $draft, style: components.linear)
            }
        case .repos:
            RepoStepView(draft: $draft, style: .cards).frame(maxWidth: maxWidth)
        case .specSource:
            WizardColumn(maxWidth: maxWidth) { SpecBlock(draft: $draft, style: components.spec) }
        case .bounds:
            WizardColumn(maxWidth: maxWidth) { BoundsBlock(draft: $draft, presentation: components.bounds) }
        case .jobs:
            Form { JobsSections(draft: $draft) }.formStyle(.grouped).frame(maxWidth: maxWidth)
        }
    }
}

// MARK: - Identity

struct IdentityBlock: View {
    @Binding var draft: AddProjectDraft
    let style: IdentityStyle
    @State private var isEditingID = false

    var body: some View {
        switch style {
        case .lockedToken: lockedToken
        case .confirmable: confirmable
        case .nameFirst: nameFirst
        case .hidden: EmptyView()
        }
    }

    private var nameBinding: Binding<String> {
        Binding { draft.name } set: { draft.setName($0) }
    }

    private var idBinding: Binding<String> {
        Binding { draft.projectID } set: { draft.setProjectID($0) }
    }

    private var lockedToken: some View {
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

    private var confirmable: some View {
        VStack(alignment: .leading, spacing: 20) {
            WizardBlock(title: "Project") {
                WizardBlockRow(label: "Name", detail: "Shown in the Sidebar. You can rename it later.") {
                    TextField("Name", text: nameBinding, prompt: Text("Acme"))
                        .labelsHidden()
                        .frame(maxWidth: 240)
                }
                Divider().padding(.leading, 12)
                WizardBlockRow(
                    label: "Project id",
                    detail: "Names the Project file, its Journal and its LaunchAgents. Permanent once added."
                ) {
                    if draft.idConfirmed {
                        HStack(spacing: 8) {
                            IdToken(id: draft.projectID)
                            Button("Change…") { draft.idConfirmed = false }.buttonStyle(.link)
                        }
                    } else {
                        TextField("Project id", text: idBinding, prompt: Text("acme"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .frame(maxWidth: 240)
                    }
                }
            }
            identityMessages
        }
    }

    private var nameFirst: some View {
        VStack(spacing: 10) {
            TextField("Project name", text: nameBinding, prompt: Text("Name your Project"))
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Divider().frame(maxWidth: 320)
            HStack(spacing: 8) {
                Text("id").foregroundStyle(.secondary)
                IdToken(id: draft.projectID)
                Button("Edit") { isEditingID = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $isEditingID, arrowEdge: .bottom) { idEditor }
            }
            Text("The id is permanent: it names the Project file, its Journal and its LaunchAgents.")
                .font(.caption)
                .foregroundStyle(.secondary)
            identityMessages
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var identityMessages: some View {
        let problems = draft.problems(in: .project).filter { $0.contains("id") || $0.contains("exists") }
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

struct LinearBlock: View { // glossary:ignore GL001
    @Binding var draft: AddProjectDraft
    let style: LinearStyle
    /// Off when the block has a step of its own, whose heading already names and explains it.
    var showsTitle = true

    var body: some View {
        switch style {
        case .choiceCards: choiceCards
        case .unifiedList: unifiedList
        }
    }

    private var choiceCards: some View {
        WizardBlock(title: showsTitle ? "Linear project" : nil, boxed: false) { // glossary:ignore GL001
            VStack(alignment: .leading, spacing: 12) {
                if showsTitle {
                    Text("Features come from one Linear project.").font(.callout).foregroundStyle(.secondary)
                }
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

    private var unifiedList: some View {
        WizardBlock(
            title: showsTitle ? "Linear project" : nil, // glossary:ignore GL001
            // glossary:ignore GL001
            footer: "Features come from this Linear project. A new one is named after the Project."
        ) {
            ForEach(AddProjectFixtures.teams) { team in
                let projects = AddProjectFixtures.linearProjects.filter { $0.teamName == team.name }
                Text(team.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(projects) { project in
                    RadioRow(
                        title: project.name,
                        isSelected: draft.linearChoice == .existing && draft.linearProjectID == project.id
                    ) {
                        draft.linearChoice = .existing
                        draft.linearProjectID = project.id
                    }
                }
                RadioRow(
                    title: "New Linear project in \(team.name)", // glossary:ignore GL001
                    subtitle: "Created when the Project is added",
                    isSelected: draft.linearChoice == .createInTeam && draft.teamKey == team.key
                ) {
                    draft.linearChoice = .createInTeam
                    draft.teamKey = team.key
                }
                if team.id != AddProjectFixtures.teams.last?.id { Divider().padding(.top, 4) }
            }
        }
    }
}
#endif
