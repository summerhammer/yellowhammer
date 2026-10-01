import Domain
import SwiftUI

/// The Add Project sheet: everything `yh setup` does, in six steps, driven by ``SetupWizardModel``. It
/// exists only to add a Project, reached from an Add Project action in a window, and it shows no status
/// or cross-Project summary. Cancelling writes no Project configuration: only `yh setup --init` writes a
/// Project file, and Cancel is disabled while it runs. (The Linear step's `--install-linear` can still
/// store the token pair and, on a Mac with no `config.toml`, write the machine file.)
struct SetupWizardView: View {
    /// Reports the added Project when the Operator presses Done, before the sheet closes.
    let onAdded: @MainActor (ProjectID) -> Void
    /// Called once each time a run finishes, whatever its exit status: a failed run may already have
    /// written the Project file, so the windows that list Projects must read again.
    let onRunEnded: @MainActor () -> Void
    @State private var model = SetupWizardModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title(for: model.currentStep))
                .font(.title2)
                .padding()
            Divider()
            ScrollView {
                content
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(model.isRunning)
        .onChange(of: model.runExitStatus) { _, status in
            if status != nil { onRunEnded() }
        }
        .onDisappear { model.terminateRun() }
    }

    @ViewBuilder private var content: some View {
        switch model.currentStep {
        case .linear:
            SetupLinearStepView(model: model)
        case .operatorIdentity:
            SetupOperatorStepView(model: model)
        case .cliRouting:
            SetupCLIRoutingStepView(model: model)
        case .project:
            SetupProjectStepView(model: model)
        case .jobs:
            SetupJobsStepView(model: model)
        case .review:
            SetupReviewStepView(model: model)
        }
    }

    private var footer: some View {
        HStack {
            if model.currentStepIndex > 0, model.runExitStatus == nil {
                Button("Back") { model.back() }
                    .accessibilityIdentifier("setup-back")
            }
            Spacer()
            if let status = model.runExitStatus, status != 0 {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("setup-close")
            } else if model.runExitStatus == nil {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("setup-cancel")
            }
            if model.runExitStatus == 0 {
                Button("Done") {
                    if let id = model.declaredProjectID { onAdded(id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup-done")
            }
            if model.runExitStatus == nil {
                Button(continueLabel) {
                    Task { await model.continueTapped() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
                .accessibilityIdentifier("setup-continue")
            }
        }
        .padding()
    }

    private var continueLabel: String {
        switch model.currentStep {
        case .linear: model.isFetchingChoices ? "Checking…" : "Continue"
        case .review: model.isRunning ? "Running…" : "Run Setup"
        default: "Continue"
        }
    }

    private func title(for step: SetupWizardModel.Step) -> String {
        switch step {
        case .linear: "Linear"
        case .operatorIdentity: "Operator identity" // glossary:ignore GL001
        case .cliRouting: "Agent CLIs and Routing Table" // glossary:ignore GL001
        case .project: "Project"
        case .jobs: "Scheduled jobs" // glossary:ignore GL001
        case .review: "Review and run"
        }
    }
}

private struct SetupOperatorStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            if let candidates = model.choices?.operatorCandidates, !candidates.isEmpty {
                Picker("Operator identity", selection: $model.selectedOperatorID) { // glossary:ignore GL001
                    Text("Choose one").tag(String?.none)
                    ForEach(candidates, id: \.id) { candidate in
                        Text("\(candidate.displayName) (\(candidate.name))").tag(Optional(candidate.id))
                    }
                }
                .accessibilityIdentifier("setup-operator-picker")
                Text("Waiting on You issues are assigned to this person.") // glossary:ignore GL001
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "The workspace has no active human members to offer as the " // glossary:ignore GL001
                        + "Operator identity."
                )
            }
        }
    }
}

private struct SetupCLIRoutingStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Section("Agent CLIs") { // glossary:ignore GL001
                ForEach(model.choices?.cliAdapters ?? [], id: \.self) { name in
                    Toggle(name, isOn: model.cliEnabledBinding(name))
                    if model.enabledCLIs.contains(name) {
                        TextField("Executable path (optional)", text: model.cliExecutableBinding(name))
                            .padding(.leading, 20)
                    }
                }
            }
            Section("Routing Table") { // glossary:ignore GL001
                TextField("Catch-all route, cli/model/effort (optional)", text: $model.routeText)
                    .accessibilityIdentifier("setup-route")
                ForEach(Array(model.fallbackTexts.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("Fallback cli/model/effort", text: $model.fallbackTexts[index])
                        Button {
                            model.fallbackTexts.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                    }
                }
                Button("Add fallback") { model.fallbackTexts.append("") }
                    .disabled(model.routeText.trimmed.isEmpty)
            }
        }
    }
}

private struct SetupProjectStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Section("Project") {
                TextField("Project id", text: $model.projectID)
                    .accessibilityIdentifier("setup-project-id")
                TextField("Name (defaults to the id)", text: $model.projectName)
            }
            Section("Linear project") { // glossary:ignore GL001
                Picker("Linear project", selection: $model.linearProjectMode) { // glossary:ignore GL001
                    Text("Existing").tag(SetupWizardModel.LinearProjectMode.existing)
                    Text("Create one in team").tag(SetupWizardModel.LinearProjectMode.createInTeam)
                }
                .pickerStyle(.segmented)
                switch model.linearProjectMode {
                case .existing:
                    TextField(
                        "Existing Linear project id", text: $model.existingLinearProjectID // glossary:ignore GL001
                    )
                    .accessibilityIdentifier("setup-linear-project-id")
                case .createInTeam:
                    Picker("Team", selection: $model.selectedTeamKey) {
                        Text("Choose a team").tag(String?.none)
                        ForEach(model.choices?.teams ?? [], id: \.id) { team in
                            Text("\(team.name) (\(team.key))").tag(Optional(team.key))
                        }
                    }
                }
            }
            Section("Spec Source") { // glossary:ignore GL001
                HStack {
                    TextField("Path (optional)", text: $model.specSource)
                    Button("Choose…") { model.chooseSpecSource() }
                }
                Text("Without a Spec Source, one Repo must have role \u{201c}spec\u{201d}.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Repos") { // glossary:ignore GL001
                ForEach($model.repos) { $repo in
                    VStack(alignment: .leading) {
                        TextField("Name", text: $repo.name)
                            .accessibilityIdentifier("setup-repo-name")
                        TextField("Role (spec, backend, mobile, web, …)", text: $repo.role) // glossary:ignore GL001
                            .accessibilityIdentifier("setup-repo-role")
                        HStack {
                            TextField("Path", text: $repo.path)
                                .accessibilityIdentifier("setup-repo-path")
                            Button("Choose…") { model.chooseRepoPath(for: repo.id) }
                        }
                        TextField("Check (\"none\" allowed)", text: $repo.check)
                            .accessibilityIdentifier("setup-repo-check")
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { model.repos.remove(atOffsets: $0) }
                Button("Add Repo") { model.repos.append(SetupWizardModel.RepoField()) } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-add-repo")
            }
            if let error = model.projectValidationError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
    }
}

private struct SetupJobsStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Picker("Scheduled jobs", selection: $model.jobsSelection) { // glossary:ignore GL001
                Text("Install the three LaunchAgents per Project").tag(SetupWizardModel.JobsSelection.install)
                Text("Export to a folder").tag(SetupWizardModel.JobsSelection.export)
                Text("Not now").tag(SetupWizardModel.JobsSelection.notNow)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("setup-jobs-picker")
            if model.jobsSelection == .export {
                HStack {
                    TextField("Export directory", text: $model.exportDirectory)
                    Button("Choose…") { model.chooseExportDirectory() }
                }
                Picker("Format", selection: $model.exportUsesCron) {
                    Text("launchd").tag(false)
                    Text("cron").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct SetupReviewStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.runExitStatus == nil {
                summary
            }
            if !model.runLines.isEmpty {
                Text(model.runLines.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("setup-run-log")
            }
            if let status = model.runExitStatus {
                if status == 0 {
                    Text("Setup complete.")
                        .accessibilityIdentifier("setup-success")
                } else {
                    Text("Setup failed; the log above explains it.")
                        .accessibilityIdentifier("setup-failure")
                }
                if let line = model.notificationStatusLine {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("setup-notification-status")
                }
            }
        }
        .padding(.vertical)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ready to run setup.")
            Text("Declares Project \u{201c}\(model.projectID)\u{201d}.")
            Text(model.jobsSummary)
        }
        .foregroundStyle(.secondary)
    }
}
