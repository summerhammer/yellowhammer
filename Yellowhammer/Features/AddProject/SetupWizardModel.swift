import Config
import Domain
import Foundation
import Observation

/// The Add Project sheet's state: the ``AddProjectDraft`` the hub edits, the machine-wide prerequisites it
/// checks, and the `yh setup --init` run. Kept as a plain `@Observable` model, not a View, so the mapping and
/// validation stay testable without driving SwiftUI (P14.2). The app never does the Board work itself
/// (ADR-001): the teams offered here come from running the bundled `yh --print-choices`, and every write
/// comes from running `yh --init`. The sheet sets nothing machine-wide: Linear auth, the Operator identity
/// and the agent CLIs live in Settings → General, and ``readiness`` blocks Add Project until they are there.
@MainActor
@Observable
final class SetupWizardModel {
    let configurationDirectory: URL

    var draft = AddProjectDraft()

    /// The machine file as last loaded; nil when it does not load, as on a Mac where Setup has never run.
    var machineConfiguration: MachineConfiguration?
    let linearInstallation = LinearInstallationModel()
    var isFetchingTeams = false
    /// `yh --print-choices`'s output when it could not list the teams; the Linear project step still takes
    /// an existing Linear project's id without them.
    var teamsFailure: [String] = []

    /// Whether the confirmation before `yh setup --init` is showing: adding is when the id becomes permanent.
    var isConfirmingAdd = false
    var isRunning = false
    var runLines: [String] = []
    var runExitStatus: Int32?
    var notificationStatusLine: String?
    var declaredProjectID: ProjectID?
    var declaredProjectName: String?
    /// The refusal as ``ProjectConfigurationModel`` reports it, when the Bounds could not be written after a
    /// successful setup. The Project stays in place with default Bounds and can be recalibrated in
    /// Settings → Recalibrate.
    var boundsFailure: String?

    let engine = SetupEngine()

    init(configurationDirectory: URL = ConfigurationDirectory.current) {
        self.configurationDirectory = configurationDirectory
        loadContext()
    }

    /// Whether each machine-wide prerequisite of Add Project is present. The sheet shows the hub only when
    /// none is missing.
    var readiness: SetupReadiness {
        SetupReadiness(linearInstalled: linearInstallation.phase.isInstalled, machine: machineConfiguration)
    }

    /// Whether the Linear installation is still being checked, so readiness is not known yet.
    var isCheckingReadiness: Bool { linearInstallation.phase == .checking }

    /// Whether Add Project can be pressed: everything is present, every step is complete, and no run started.
    var canAddProject: Bool {
        !readiness.blocksAddProject && draft.isComplete && !isRunning && runExitStatus == nil
    }

    /// Reads the Project files, the Journal file names and the configuration under `configurationDirectory`
    /// into `draft.context` and `machineConfiguration`. Only files are read, and no Journal is opened.
    func loadContext() {
        let fileManager = FileManager.default
        func baseNames(in folder: String, extension fileExtension: String) -> Set<String> {
            let directory = configurationDirectory.appending(path: folder, directoryHint: .isDirectory)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            return Set(
                names.filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension == fileExtension }
                    .map { ($0 as NSString).deletingPathExtension }
            )
        }
        let projectFileIDs = baseNames(in: "projects", extension: "toml")
        let journalProjectIDs = baseNames(in: "journals", extension: "db")
        let teams = draft.context.teams
        if let configuration = try? Configuration.load(directory: configurationDirectory) {
            machineConfiguration = configuration.machine
            draft.context = AddProjectContext(
                configuration: configuration, projectFileIDs: projectFileIDs,
                journalProjectIDs: journalProjectIDs, teams: teams,
                // One installation until the wizard offers a choice (roadmap L3.1).
                linearInstallationName: configuration.machine.soleLinearInstallation?.name
            )
        } else {
            machineConfiguration = nil
            draft.context = AddProjectContext(
                existingProjectIDs: projectFileIDs, journalProjectIDs: journalProjectIDs, teams: teams
            )
        }
    }

    /// Asks before adding; the confirmation's Add Project runs ``confirmAndRun()``.
    func requestAdd() {
        guard canAddProject else { return }
        isConfirmingAdd = true
    }

    /// The Operator confirmed the id: it is permanent from here.
    func confirmAndRun() async {
        draft.idConfirmed = true
        await runSetup()
    }

    /// Terminates the current run, if any: closing the Add Project sheet is not an Act, so nothing must
    /// survive it.
    func terminateRun() {
        linearInstallation.terminate()
        engine.terminate()
    }
}
