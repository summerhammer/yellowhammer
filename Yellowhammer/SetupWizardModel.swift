import AppKit
import Config
import Domain
import Foundation
import Observation
import SwiftUI
import UserNotifications

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

/// The Setup wizard's state and the mapping from its form fields to ``SetupInvocation``. Kept as a plain
/// `@Observable` model, not a View, so the mapping and validation are testable without driving SwiftUI
/// (P14.2). The app never does the Board work itself (ADR-001): every choice offered here comes from
/// running the bundled `yh --print-choices`, and every write comes from running `yh --init`.
@MainActor
@Observable
final class SetupWizardModel {
    enum Step: CaseIterable {
        case linear
        case operatorIdentity
        case cliRouting
        case project
        case jobs
        case review
    }

    enum LinearProjectMode: Hashable { // glossary:ignore GL001
        case existing
        case createInTeam
    }

    enum JobsSelection: Hashable {
        case install
        case export
        case notNow
    }

    struct RepoField: Identifiable {
        let id = UUID()
        var name = ""
        var role = ""
        var path = ""
        var check = ""
    }

    static let defaultLinearCredential = "keychain:linear"
    static let defaultGitHubCredential = "keychain:github"

    let configurationDirectory: URL

    // Step: Linear
    var configExists: Bool
    var linearClientID = ""
    var linearSecret = ""
    var linearCredential = SetupWizardModel.defaultLinearCredential
    var githubCredential = SetupWizardModel.defaultGitHubCredential
    var showAdvanced = false
    var isFetchingChoices = false
    var choicesErrorOutput: [String] = []
    var choices: SetupChoices?

    // Step: Operator identity
    var selectedOperatorID: String?

    // Step: Agent CLIs and Routing Table
    var enabledCLIs: Set<String> = []
    var cliExecutables: [String: String] = [:]
    var routeText = ""
    var fallbackTexts: [String] = []

    // Step: Project
    var declareProject: Bool
    var projectID = ""
    var projectName = ""
    var linearProjectMode: LinearProjectMode = .existing
    var existingLinearProjectID = ""
    var selectedTeamKey: String?
    var specSource = ""
    var repos: [RepoField] = [RepoField()]

    // Step: Scheduled jobs
    var jobsSelection: JobsSelection = .install
    var exportDirectory = ""
    var exportUsesCron = false

    // Step: Review and run
    var currentStepIndex = 0
    var isRunning = false
    var runLines: [String] = []
    var runExitStatus: Int32?
    var notificationStatusLine: String?
    var declaredProjectID: ProjectID?
    var declaredProjectName: String?

    let engine = SetupEngine()

    init(configurationDirectory: URL = ConfigurationDirectory.current) {
        self.configurationDirectory = configurationDirectory
        configExists = ConfigurationDirectory.machineFileExists(in: configurationDirectory)
        declareProject = ConfiguredProjects.load().entries.isEmpty
    }

    var activeSteps: [Step] {
        configExists ? [.linear, .operatorIdentity, .project, .jobs, .review] : Step.allCases
    }

    /// Clamped rather than a bare subscript: `activeSteps` shrinks the moment `configExists` flips (the
    /// CLI/Routing step drops out), which can otherwise leave `currentStepIndex` pointing past the end.
    var currentStep: Step { activeSteps[min(currentStepIndex, activeSteps.count - 1)] }

    var canContinue: Bool {
        switch currentStep {
        case .linear:
            guard !isFetchingChoices else { return false }
            guard !configExists else { return true }
            return !linearClientID.trimmed.isEmpty && !linearSecret.trimmed.isEmpty
        case .operatorIdentity:
            return selectedOperatorID != nil
        case .cliRouting:
            return true
        case .project:
            return !declareProject || projectValidationError == nil
        case .jobs:
            switch jobsSelection {
            case .export: return !exportDirectory.trimmed.isEmpty
            case .install, .notNow: return true
            }
        case .review:
            return !isRunning
        }
    }

    /// Nil when the Project step's fields describe a valid declaration; a human sentence otherwise.
    var projectValidationError: String? {
        guard declareProject else { return nil }
        let trimmedID = projectID.trimmed
        guard !trimmedID.isEmpty, ProjectID(rawValue: trimmedID) != nil else {
            return "Enter a Project id of letters, digits, underscores and hyphens."
        }
        let projectFileURL = configurationDirectory.appending(
            components: "projects", "\(trimmedID).toml", directoryHint: .notDirectory
        )
        guard !FileManager.default.fileExists(atPath: projectFileURL.path(percentEncoded: false)) else {
            return "A Project file for \u{201c}\(trimmedID)\u{201d} already exists."
        }
        switch linearProjectMode {
        case .existing:
            guard !existingLinearProjectID.trimmed.isEmpty else {
                return "Enter an existing Linear project id, or choose to create " // glossary:ignore GL001
                    + "one in a team."
            }
        case .createInTeam:
            guard selectedTeamKey != nil else {
                return "Choose a team to create the Linear project in." // glossary:ignore GL001
            }
        }
        guard !repos.isEmpty else { return "Add at least one Repo." }
        // `check` is never defaulted: `check = "none"` is declared, so silence never means "no gate".
        for repo in repos where [repo.name, repo.role, repo.path, repo.check].contains(where: \.trimmed.isEmpty) {
            return "Every Repo needs a name, role, path and check (\u{201c}none\u{201d} where nothing runs)."
        }
        if specSource.trimmed.isEmpty && !repos.contains(where: { $0.role.trimmed == "spec" }) {
            return "Without a Spec Source, one Repo must have role \u{201c}spec\u{201d}."
        }
        return nil
    }

    var jobsSummary: String {
        switch jobsSelection {
        case .install: "Installs the three LaunchAgents per Project."
        case .export: "Exports the scheduled jobs to \(exportDirectory)."
        case .notNow: "Scheduled jobs are not generated now."
        }
    }

    func cliEnabledBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { self.enabledCLIs.contains(name) },
            set: { enabled in
                if enabled { self.enabledCLIs.insert(name) } else { self.enabledCLIs.remove(name) }
            }
        )
    }

    func cliExecutableBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { self.cliExecutables[name] ?? "" },
            set: { self.cliExecutables[name] = $0 }
        )
    }

    func back() {
        guard currentStepIndex > 0 else { return }
        currentStepIndex -= 1
    }

    func continueTapped() async {
        switch currentStep {
        case .linear:
            await fetchChoices()
        case .review:
            await runSetup()
        default:
            advance()
        }
    }

    func advance() {
        guard currentStepIndex < activeSteps.count - 1 else { return }
        currentStepIndex += 1
    }

    /// Terminates the current run, if any: closing the Setup window is not an Act, so nothing must
    /// survive it.
    func terminateRun() {
        engine.terminate()
    }

    func startAnotherProject() {
        declareProject = true
        projectID = ""
        projectName = ""
        existingLinearProjectID = ""
        selectedTeamKey = nil
        specSource = ""
        repos = [RepoField()]
        runLines = []
        runExitStatus = nil
        notificationStatusLine = nil
        declaredProjectID = nil
        declaredProjectName = nil
        currentStepIndex = activeSteps.firstIndex(of: .project) ?? 0
    }
}
