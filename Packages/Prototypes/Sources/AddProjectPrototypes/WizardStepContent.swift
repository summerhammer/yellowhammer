#if DEBUG
import SwiftUI

// The fields of each step, shared by every variant so the variants differ in layout and components,
// not in what they ask. A variant picks a Repo list style and a Bounds style; the rest is one grouped
// Form per step.

extension EnvironmentValues {
    /// Every way out of the sheet (Cancel, Done, Close). The Playground records each call.
    @Entry var addProjectAction: @MainActor (String) -> Void = { _ in }
}

enum RepoListStyle {
    /// The wireframe: a path, a role chip and a Check pill per row.
    case rows
    /// An editable table, a column per field.
    case table
    /// A card per Repo with every field laid out.
    case cards
}

enum BoundsStyle {
    /// A stepper per Bound, the three Feature-level ones folded away.
    case steppers
    /// A dense grid of number fields with their TOML keys.
    case grid
}

/// One step's fields.
struct WizardStepContent: View {
    let step: WizardStep
    @Binding var draft: AddProjectDraft
    var repoStyle: RepoListStyle = .rows
    var boundsStyle: BoundsStyle = .steppers

    var body: some View {
        switch step {
        case .project:
            Form { ProjectSections(draft: $draft) }.formStyle(.grouped)
        case .repos:
            RepoStepView(draft: $draft, style: repoStyle)
        case .specSource:
            Form { SpecSourceSections(draft: $draft) }.formStyle(.grouped)
        case .bounds:
            Form { BoundsSections(draft: $draft, style: boundsStyle) }.formStyle(.grouped)
        case .jobs:
            Form { JobsSections(draft: $draft) }.formStyle(.grouped)
        }
    }
}

// MARK: - Project & Linear project

struct ProjectSections: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        Section {
            TextField("Project id", text: $draft.projectID, prompt: Text("acme"))
            TextField(
                "Name", text: $draft.name,
                prompt: Text(draft.projectID.isEmpty ? "Defaults to the id" : draft.projectID)
            )
        } header: {
            Text("Project")
        } footer: {
            Text("The id names the Project file and every LaunchAgent. It cannot change later.")
                .foregroundStyle(.secondary)
        }
        Section("Linear project") { // glossary:ignore GL001
            Picker("Source", selection: $draft.linearChoice) {
                Text("Existing").tag(LinearProjectChoice.existing)
                Text("Create in a team").tag(LinearProjectChoice.createInTeam)
            }
            .pickerStyle(.segmented)
            switch draft.linearChoice {
            case .existing:
                Picker("Linear project", selection: $draft.linearProjectID) { // glossary:ignore GL001
                    Text("Choose…").tag(String?.none)
                    ForEach(AddProjectFixtures.linearProjects) { project in
                        Text("\(project.name) — \(project.teamName)").tag(Optional(project.id))
                    }
                }
            case .createInTeam:
                Picker("Team", selection: $draft.teamKey) {
                    Text("Choose…").tag(String?.none)
                    ForEach(AddProjectFixtures.teams) { Text("\($0.name) (\($0.key))").tag(Optional($0.key)) }
                }
            }
        }
    }
}

// MARK: - Spec Source

struct SpecSourceSections: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        Section {
            Picker("Specification source", selection: $draft.specChoice) {
                Text("A Spec Source folder").tag(SpecSourceChoice.path)
                Text("One of this Project\u{2019}s Repos").tag(SpecSourceChoice.repo)
            }
            .pickerStyle(.radioGroup)
        } footer: {
            Text("Exactly one: a Project with none, or with both kinds, is refused at load.")
                .foregroundStyle(.secondary)
        }
        switch draft.specChoice {
        case .path:
            Section("Spec Source") {
                LabeledContent("Folder") {
                    HStack {
                        Text(draft.specSourcePath.isEmpty ? "None" : draft.summary(of: .specSource))
                            .font(.body.monospaced())
                            .foregroundStyle(draft.specSourcePath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { draft.chooseSpecSource() }
                    }
                }
                Text("Read-only and shareable across Projects. It has no Repo Role, Check or Protected Paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .repo:
            Section("Spec Repo") {
                ForEach(draft.repos) { repo in
                    Toggle(isOn: specBinding(repo.id)) {
                        Text(repo.name)
                        Text(repo.displayPath).font(.caption.monospaced())
                    }
                }
                if draft.repos.isEmpty {
                    Text("Add a Repo first.").foregroundStyle(.secondary)
                }
            }
        }
        if !draft.problems(in: .specSource).isEmpty {
            Section { WizardProblemList(problems: draft.problems(in: .specSource)) }
        }
    }

    /// On sets the Repo's role to "spec"; off clears it so the Operator picks a working role again.
    private func specBinding(_ id: RepoDraft.ID) -> Binding<Bool> {
        Binding {
            draft.repos.first { $0.id == id }?.role == "spec"
        } set: { isSpec in
            guard let index = draft.repos.firstIndex(where: { $0.id == id }) else { return }
            draft.repos[index].role = isSpec ? "spec" : AddProjectFixtures.guessedRole(for: draft.repos[index].path)
        }
    }
}

// MARK: - Bounds

struct BoundsSections: View {
    @Binding var draft: AddProjectDraft
    let style: BoundsStyle
    @State private var showsFeatureBounds = false

    var body: some View {
        switch style {
        case .steppers:
            Section {
                ForEach(BoundsDraft.cardLevel, id: \.key) { bound in
                    Stepper(value: $draft.bounds[dynamicMember: bound.keyPath], in: 1...20) {
                        LabeledContent(bound.label, value: draft.bounds[keyPath: bound.keyPath], format: .number)
                    }
                }
            } header: {
                Text("Per Card")
            } footer: {
                Text("Every Bound is per-Project; there are no machine-wide Bounds.").foregroundStyle(.secondary)
            }
            Section(isExpanded: $showsFeatureBounds) {
                ForEach(BoundsDraft.featureLevel, id: \.key) { bound in
                    Stepper(value: $draft.bounds[dynamicMember: bound.keyPath], in: 1...20) {
                        LabeledContent(bound.label, value: draft.bounds[keyPath: bound.keyPath], format: .number)
                    }
                }
            } header: {
                Text("Per Feature")
            }
            Section {
                Button("Restore Defaults") { draft.bounds = BoundsDraft() }
                    .disabled(draft.bounds.isDefault)
            }
        case .grid:
            Section {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(BoundsDraft.all, id: \.key) { bound in
                        GridRow {
                            Text(bound.label)
                            TextField(
                                bound.label, value: $draft.bounds[dynamicMember: bound.keyPath], format: .number
                            )
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                            Text(bound.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                WizardProblemList(problems: draft.problems(in: .bounds))
            }
        }
    }
}

// MARK: - Scheduled jobs

struct JobsSections: View {
    @Binding var draft: AddProjectDraft

    private static let times = (0..<24).map { String(format: "%02d:00", $0) }

    var body: some View {
        Section("The Night") {
            Picker("Starts", selection: $draft.nightStart) {
                ForEach(Self.times, id: \.self) { Text($0).tag($0) }
            }
            Picker("Ends", selection: $draft.nightEnd) {
                ForEach(Self.times, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $draft.buildEveryMinutes, in: 5...120, step: 5) {
                LabeledContent("Build every", value: "\(draft.buildEveryMinutes) min")
            }
        }
        Section {
            Picker("Scheduled jobs", selection: $draft.jobs) { // glossary:ignore GL001
                Text("Install the three LaunchAgents").tag(JobsChoice.install)
                Text("Export to a folder").tag(JobsChoice.export)
                Text("Not now").tag(JobsChoice.notNow)
            }
            .pickerStyle(.radioGroup)
            if draft.jobs == .export {
                LabeledContent("Folder") {
                    HStack {
                        Text(draft.exportDirectory.isEmpty ? "None" : draft.exportDirectory)
                            .font(.body.monospaced())
                            .foregroundStyle(draft.exportDirectory.isEmpty ? .secondary : .primary)
                        Button("Choose…") { draft.chooseExportDirectory() }
                    }
                }
                Picker("Format", selection: $draft.exportUsesCron) {
                    Text("launchd").tag(false)
                    Text("cron").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Scheduled jobs") // glossary:ignore GL001
        } footer: {
            Text("launchd runs author, build and land for this Project. The Night runs with the app quit.")
                .foregroundStyle(.secondary)
        }
        if !draft.problems(in: .jobs).isEmpty {
            Section { WizardProblemList(problems: draft.problems(in: .jobs)) }
        }
    }
}

// MARK: - Run

/// The last screen every variant shares: the fixture run's log and its outcome.
struct WizardRunView: View {
    let draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch draft.run {
            case .notStarted, .running:
                ProgressView("Adding \(draft.displayName)…")
            case .succeeded:
                Label("\(draft.displayName) is added", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WizardTheme.success)
                Text("Its first Night starts at \(draft.nightStart). Change it later in Settings.")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Setup failed", systemImage: "xmark.octagon.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WizardTheme.error)
                Text("The log below explains it. The Project file may already be written; Settings lists it.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(draft.runLog.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 8))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Small parts

/// A step's problems in `error`, at most `limit` of them.
struct WizardProblemList: View {
    let problems: [String]
    var limit = Int.max

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems.prefix(limit), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(WizardTheme.error)
            }
        }
    }
}

/// The wireframe's note under the Repos.
struct WizardFootnote: View {
    var body: some View {
        Text("The wizard runs only when adding a Project. Afterwards its Configuration is a single screen in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A step's status as its symbol in its colour.
struct WizardStatusIcon: View {
    let status: WizardStepStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .foregroundStyle(status.color)
            .accessibilityLabel(String(describing: status))
    }
}

/// The footer's bottom-right: Back, then Continue or Add Project, or Done and Close after a run.
struct WizardNavigationButtons: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    var body: some View {
        switch draft.run {
        case .succeeded:
            Button("Done") { action("Done — select \(draft.displayName) in the Sidebar") }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Back to Review") { draft.run = .notStarted }
            Button("Close") { action("Close after a failed run") }
                .keyboardShortcut(.defaultAction)
        case .notStarted, .running:
            if !draft.isFirstStep {
                Button("Back") { draft.goBack() }
            }
            Button(draft.continueTitle) { draft.goForward() }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canContinue)
        }
    }
}

/// Cancel, which writes nothing.
struct WizardCancelButton: View {
    var caption = true
    @Environment(\.addProjectAction) private var action

    var body: some View {
        Button("Cancel") { action("Cancel — leaves nothing behind") }
            .keyboardShortcut(.cancelAction)
        if caption {
            Text("leaves nothing behind").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Binding where Value == AddProjectDraft {
    /// A binding to one Repo by id, safe against the Repo being removed mid-render.
    func repo(_ id: RepoDraft.ID) -> Binding<RepoDraft> {
        Binding<RepoDraft> {
            wrappedValue.repos.first { $0.id == id } ?? RepoDraft(path: "")
        } set: { newValue in
            guard let index = wrappedValue.repos.firstIndex(where: { $0.id == id }) else { return }
            wrappedValue.repos[index] = newValue
        }
    }
}
#endif
