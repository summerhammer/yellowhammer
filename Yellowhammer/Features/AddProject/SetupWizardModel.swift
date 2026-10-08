import Config
import Domain
import Foundation
import Journal
import Observation

/// The Add Project sheet's state: the ``AddProjectDraft`` the hub edits, the machine-wide prerequisite it
/// checks, and the `yh setup --init` run. Kept as a plain `@Observable` model, not a View, so the mapping and
/// validation stay testable without driving SwiftUI (P14.2). The app never does the Board work itself
/// (ADR-001): the teams offered here come from running the bundled `yh --print-choices`, and every write
/// comes from running `yh`. The agent CLI route lives in Settings → Agent CLIs, and ``readiness`` blocks Add
/// Project until it is there. The Linear workspace and its Operator identity are chosen in the Linear step
/// through ``linearWorkspaces``; a workspace connected there is machine configuration, not the Project's, so
/// it stays in `config.toml` when the sheet is cancelled and nothing undoes it. The Code Hosting step works the same
/// way through ``codeHosting``: a connection created there is machine-wide and stays in the
/// registry when the sheet is cancelled; nothing else is written until the run.
@MainActor
@Observable
final class SetupWizardModel {
    let configurationDirectory: URL

    var draft = AddProjectDraft()

    /// The machine file as last loaded; nil when it does not load, as on a Mac where Setup has never run.
    var machineConfiguration: MachineConfiguration?
    /// The Board connections list the Linear step chooses from, and connects another to.
    let linearWorkspaces: LinearWorkspacesModel
    /// The Code Hosting step checks the selected connection against the working Repos, with each report written into
    /// the draft.
    let codeHosting: CodeHostingConnectionsModel
    let codeHostingCheck = CodeHostingCheckModel()
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
    /// The `--print-choices` run for the selected installation; a new one per fetch, so a stale run can be
    /// terminated without disturbing the next.
    @ObservationIgnored var teamsEngine = SetupEngine()
    @ObservationIgnored var teamsFetchGeneration = 0
    /// The `--print-choices --linear-project` run verifying a pasted project id.
    @ObservationIgnored var verifyEngine = SetupEngine()
    @ObservationIgnored var verifyGeneration = 0

    init(configurationDirectory: URL = ConfigurationDirectory.current) {
        self.configurationDirectory = configurationDirectory
        linearWorkspaces = LinearWorkspacesModel(directory: configurationDirectory)
        codeHosting = CodeHostingConnectionsModel(directory: configurationDirectory)
        codeHosting.onConnected = { [weak self] name in
            self?.loadContext()
            self?.draft.codeHostingConnectionName = name
            self?.draft.gitHubReport = nil
        }
        linearWorkspaces.onConnected = { [weak self] name in
            guard let self else { return }
            loadContext()
            Task { await self.selectLinearInstallation(name) }
        }
        linearWorkspaces.onChanged = { [weak self] in self?.loadContext() }
        codeHostingCheck.onReport = { [weak self] report, connection, repoPaths in
            self?.draft.codeHostingCheckedConnectionName = connection
            self?.draft.gitHubReport = report
            self?.draft.gitHubCheckedRepoPaths = repoPaths
        }
        loadContext()
    }

    /// Whether the machine-wide prerequisite of Add Project is present. The sheet shows the hub only when
    /// it is.
    var readiness: SetupReadiness {
        SetupReadiness(machine: machineConfiguration)
    }

    /// Whether Add Project can be pressed: everything is present, every step is complete, and no run started.
    var canAddProject: Bool {
        !readiness.blocksAddProject && draft.isComplete && !isRunning && runExitStatus == nil
    }

    /// Reads the Project files, the Journal file names and the configuration under `configurationDirectory`
    /// into `draft.context` and `machineConfiguration`, and reloads ``linearWorkspaces`` to match (unless an
    /// Operator choice is mid-edit). The Journal of an id that has no Project file is opened read-only to learn
    /// its Linear workspace; nothing is ever written (the app may read Journals). A selected installation that
    /// is gone from the registry stays selected: validation reports it. Once the run started the draft is
    /// frozen: reading again would find the Project the run just wrote, and report the draft's own id and
    /// Repos as taken by it.
    func loadContext() {
        guard !hasStartedRun else { return }
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
        let keptJournals = readKeptJournals(ids: journalProjectIDs.subtracting(projectFileIDs))
        let teams = draft.context.teams
        let linearProjects = draft.context.linearProjects
        linearWorkspaces.reloadIfClean()
        codeHosting.reloadIfClean()
        if draft.codeHostingConnectionName == nil, codeHosting.connections.contains(where: { $0.kind == .gh }) {
            draft.codeHostingConnectionName = codeHosting.connections.first { $0.kind == .gh }?.name
        }
        if let configuration = try? Configuration.load(directory: configurationDirectory) {
            machineConfiguration = configuration.machine
            draft.context = AddProjectContext(
                configuration: configuration, projectFileIDs: projectFileIDs,
                journalProjectIDs: journalProjectIDs, teams: teams, linearProjects: linearProjects,
                keptJournals: keptJournals
            )
        } else {
            machineConfiguration = nil
            draft.context = AddProjectContext(
                existingProjectIDs: projectFileIDs, journalProjectIDs: journalProjectIDs, teams: teams,
                linearProjects: linearProjects, keptJournals: keptJournals
            )
        }
    }

    /// What each kept Journal records, opened read-only. An id that is not a valid `ProjectID` is skipped.
    private func readKeptJournals(ids: Set<String>) -> [String: AddProjectContext.KeptJournal] {
        var kept: [String: AddProjectContext.KeptJournal] = [:]
        for id in ids {
            guard let projectID = ProjectID(rawValue: id) else { continue }
            let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
            do {
                kept[id] = .workspace(try JournalStore.openReadOnly(at: fileURL, projectID: projectID).linearWorkspace)
            } catch {
                kept[id] = .unreadable("\(error)")
            }
        }
        return kept
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
        linearWorkspaces.terminate()
        codeHosting.terminate()
        codeHostingCheck.terminate()
        teamsEngine.terminate()
        verifyEngine.terminate()
        engine.terminate()
    }
}
