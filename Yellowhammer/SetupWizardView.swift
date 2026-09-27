import Domain
import SwiftUI

/// The Setup window: everything `yh setup` does, in six steps, driven by ``SetupWizardModel``. Not
/// Project-scoped — declaring a new Project happens here, not in a Project window — and it shows no
/// status or cross-Project summary.
struct SetupWizardView: View {
    @State private var model = SetupWizardModel()

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

private struct SetupLinearStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Section("Linear") { // glossary:ignore GL001
                Text(
                    "Yellowhammer connects to Linear through its own app, installed once " // glossary:ignore GL001
                        + "by a workspace admin."
                )
                .foregroundStyle(.secondary)
                linearInstallContent
            }
            if !model.configExists {
                DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
                    TextField("GitHub credential reference", text: $model.githubCredential)
                }
            }
            if !model.choicesErrorOutput.isEmpty {
                Section("yh output") {
                    Text(model.choicesErrorOutput.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .task { await model.checkExistingLinearInstallation() }
    }

    @ViewBuilder private var linearInstallContent: some View {
        switch model.linearInstallPhase {
        case .checking:
            ProgressView("Checking for an existing installation…")
                .accessibilityIdentifier("setup-linear-checking")
        case .notInstalled:
            Button("Install in Linear…") { model.startLinearInstall() } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-install")
        case .installing(let adminStatement):
            if !adminStatement.isEmpty {
                Text(adminStatement).font(.callout)
            }
            ProgressView()
        case .awaitingApproval(let adminStatement):
            if !adminStatement.isEmpty {
                Text(adminStatement).font(.callout)
            }
            Text("Waiting for a workspace admin to approve in the browser…") // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-awaiting")
            Button("Cancel") { model.cancelLinearInstall() }
        case .portsBusy(let text, let ports):
            Text(text).accessibilityIdentifier("setup-linear-ports-busy")
            ForEach(ports, id: \.port) { port in
                Text("Port \(port.port)\(port.command.map { " — \($0)" } ?? "")")
                    .font(.system(.footnote, design: .monospaced))
            }
            HStack {
                Button("Retry") { model.startLinearInstall() } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-linear-retry")
                Button("Cancel") { model.cancelLinearInstall() }
            }
        case .failed(let text):
            Text(text).accessibilityIdentifier("setup-linear-failed")
            Button("Install again") { model.startLinearInstall() } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-install")
        case .installed(let workspaceName):
            Text(workspaceName.map { "Installed in the Linear workspace \($0)." } ?? "Installed.")
                .accessibilityIdentifier("setup-linear-installed")
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
                    .disabled(model.routeText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private struct SetupProjectStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Toggle("Declare a Project", isOn: $model.declareProject)
                .accessibilityIdentifier("setup-declare-project")
            if model.declareProject {
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

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
                HStack {
                    if status == 0 {
                        if let id = model.declaredProjectID {
                            Button("Open \(model.declaredProjectName ?? id.rawValue)") { // glossary:ignore GL001
                                openWindow(value: id)
                            }
                        }
                        Button("Declare another Project") { model.startAnotherProject() } // glossary:ignore GL001
                    }
                    Button("Done") { dismiss() }
                }
            }
        }
        .padding(.vertical)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ready to run setup.")
            if model.declareProject {
                Text("Declares Project \u{201c}\(model.projectID)\u{201d}.")
            }
            Text(model.jobsSummary)
        }
        .foregroundStyle(.secondary)
    }
}
