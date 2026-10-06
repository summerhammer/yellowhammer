import Config
import Domain
import Foundation
import Observation

/// The Board connections list, in Settings → Boards (L3.1) and in the Add Project wizard's
/// Linear step (L3.2): one row per Board Connection in `config.toml`'s
/// `[board.linear.connections.<name>]` registry, with per row a re-connect, a removal and the Operator
/// identity, and one connect-another install. The app decides nothing (ADR-001): every change is a `yh`
/// invocation built in `Domain`, `config.toml` is only ever read here, and a refusal is `yh`'s own words.
///
/// The child models (a re-connect and an Operator identity per row) are keyed by the installation's local
/// name and kept across reloads, so a reload never kills a running install; a row that disappears drops
/// its models. Owned by `SettingsWindow` or by the wizard's model, so another sidebar row and back neither
/// recreates it nor kills a running install.
@MainActor
@Observable
final class LinearWorkspacesModel {
    /// One Board Connection as `config.toml` holds it, plus the Projects that name it.
    struct Workspace: Identifiable, Equatable {
        /// The local name, the registry key.
        let name: String
        /// The Linear workspace ID: an opaque vendor ID, never shown as a label.
        let workspaceID: String
        /// The Linear user the installation's app acts as, an opaque vendor ID.
        let appUser: BoardObjectID
        let operatorIdentity: BoardObjectID?
        /// Ids of the Projects whose `[board.linear] installation` names this one, from the local files.
        let projects: [String]

        var id: String { name }
    }

    /// What `yh doctor --check linear --json` said about one installation.
    struct Status: Equatable {
        let workspaceName: String?
        let check: LinearInstallationStatus
        /// The live check's verdict on its authorization; only `.refused` offers *Remove anyway…* (OQ121).
        var authorization: InstallationAuthorizationState?
    }

    let directory: URL
    private(set) var workspaces: [Workspace] = []
    /// Whether `config.toml` does not exist yet: no rows, and connecting is still offered.
    private(set) var configMissing = false
    /// Why `config.toml` could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?
    /// The Project files that failed to decode. Any one blocks every *Remove*: it may name the
    /// installation, and `yh` refuses the removal while it cannot know (OQ109 item 14).
    private(set) var invalidProjectFiles: [String] = []
    /// The doctor's reading per installation name; an installation the doctor said nothing about is absent.
    private(set) var statuses: [String: Status] = [:]
    /// `yh`'s lines after a removal it refused, per installation, shown verbatim in that row.
    private(set) var removalFailures: [String: [String]] = [:]
    /// `yh`'s lines after the last removal it accepted.
    private(set) var removalMessage: [String] = []
    /// The installation whose removal is running; one at a time.
    private(set) var removing: String?
    /// The install that adds a workspace to the registry (untargeted).
    let connectAnother = LinearInstallationModel(installation: nil, phase: .notInstalled)

    /// Called after a connect-another install finished and the list reloaded, with the connected entry's
    /// local name, so the Add Project wizard can select it.
    @ObservationIgnored var onConnected: (@MainActor (String) -> Void)?
    /// Called after an Operator identity was saved and the list reloaded.
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?

    @ObservationIgnored private var reconnectModels: [String: LinearInstallationModel] = [:]
    @ObservationIgnored private var operatorModels: [String: OperatorIdentityModel] = [:]
    private let doctorEngine = SetupEngine()
    private let removalEngine = SetupEngine()
    private var didRefreshOnAppearance = false
    private var isRefreshing = false
    private var refreshQueued = false

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        connectAnother.onInstalled = { [weak self] in self?.installFinished(connectAnother: true, name: nil) }
        load()
    }

    // MARK: Rows

    /// The label a row shows: the workspace name when the doctor read it, else the local name.
    func label(for workspace: Workspace) -> String {
        LinearInstallationStatus.label(
            workspaceName: statuses[workspace.name]?.workspaceName, localName: workspace.name
        )
    }

    func reconnectModel(for name: String) -> LinearInstallationModel? { reconnectModels[name] }

    func operatorModel(for name: String) -> OperatorIdentityModel? { operatorModels[name] }

    // MARK: Reading

    /// Reads `config.toml` and the Project files in `directory`. Never writes. The removal-shaped load,
    /// as `yh config remove-board-connection` reads them: a Project naming a missing installation still loads,
    /// so it never blocks another installation's *Remove*.
    func load() {
        do {
            let machineFile = directory.appending(component: "config.toml", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: machineFile.path(percentEncoded: false)) else {
                configMissing = true
                loadFailure = nil
                invalidProjectFiles = []
                apply([])
                return
            }
            let configuration = try Configuration.loadLeniently(directory: directory)
            configMissing = false
            loadFailure = nil
            invalidProjectFiles = configuration.invalidProjects.map(\.file).sorted()
            apply(configuration.machine.linearInstallations.map { installation in
                Workspace(
                    name: installation.name,
                    workspaceID: installation.workspace.rawValue,
                    appUser: installation.appUser,
                    operatorIdentity: installation.operatorIdentity,
                    projects: configuration.projects
                        .filter { $0.linearInstallationName == installation.name }
                        .map(\.id.rawValue)
                )
            })
        } catch {
            configMissing = false
            loadFailure = error.description
            invalidProjectFiles = []
            apply([])
        }
    }

    /// Reloads on app activation, but leaves alone a dirty Operator picker, a running candidate fetch or
    /// save, and a running removal.
    func reloadIfClean() {
        guard removing == nil,
              !operatorModels.values.contains(where: { $0.isDirty || $0.isFetching || $0.isSaving })
        else { return }
        load()
    }

    /// The pane's first appearance: reads the doctor's status once; later appearances (another sidebar row
    /// and back) and app activations do not run it again. The read runs in a task of the model's own, not
    /// the view's: a view's task is cancelled when navigation recreates the pane, which would end the read
    /// half-way with nothing left to retry it.
    func refreshStatusOnFirstAppearance() {
        guard !didRefreshOnAppearance else { return }
        didRefreshOnAppearance = true
        Task { await refreshStatus() }
    }

    /// Runs `yh doctor --check linear --json` once for the whole list. `yh` always reads the real
    /// configuration, so while the app is pointed at another one (a UI test's fixture) the check is not
    /// run unless a stub stands in for `yh`.
    func refreshStatus() async {
        guard !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed else { return }
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            var lines: [String] = []
            let status = try? await doctorEngine.run(arguments: ["doctor", "--check", "linear", "--json"]) {
                lines.append($0)
            }
            guard status != nil, let rows = DoctorFindingRow.decodeLastLine(lines) else {
                statuses = [:]
                continue
            }
            var updated: [String: Status] = [:]
            for workspace in workspaces {
                let check = LinearInstallationStatus.interpret(rows, installation: workspace.name)
                let name = LinearInstallationStatus.workspaceName(in: rows, installation: workspace.name)
                let authorization = DoctorFindingRow.authorizationState(in: rows, installation: workspace.name)
                if check != .unknown || name != nil || authorization != nil {
                    updated[workspace.name] = Status(
                        workspaceName: name, check: check, authorization: authorization
                    )
                }
            }
            statuses = updated
        } while refreshQueued
    }

    // MARK: Removing

    /// Why *Remove* is disabled for `workspace`, or nil when it is offered: Projects name it, or a Project
    /// file failed to decode. The spec's form of `yh`'s own refusal, shown instead of offering and refusing.
    func removalBlock(for workspace: Workspace) -> String? {
        var reasons: [String] = []
        if !workspace.projects.isEmpty {
            let plural = workspace.projects.count != 1
            reasons.append(
                "Used by \(workspace.projects.joined(separator: ", ")); remove "
                    + (plural ? "those Projects" : "that Project") + " first."
            )
        }
        if !invalidProjectFiles.isEmpty {
            reasons.append(
                "These Project files failed to decode, so whether they use this workspace cannot be known: "
                    + invalidProjectFiles.joined(separator: ", ") + "."
            )
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: " ")
    }

    /// Whether *Remove anyway…* is offered (OQ121 item 11): Projects name the installation, no Project file
    /// is undecodable, and the doctor's live check found its authorization refused — never for an unreachable
    /// Linear. `yh` runs the same gate again when it is confirmed.
    func offersOrphanRemoval(for workspace: Workspace) -> Bool {
        !workspace.projects.isEmpty && invalidProjectFiles.isEmpty
            && statuses[workspace.name]?.authorization == .refused
    }

    /// Runs `yh config remove-board-connection <name>`, with `--orphan-projects --yes` for *Remove anyway…*
    /// (whose dialog was the confirmation). Exit 0: reloads, refreshes and keeps `yh`'s lines as the list's
    /// success message. Otherwise `yh`'s lines are that row's refusal, verbatim.
    func remove(_ name: String, orphanProjects: Bool = false) async {
        guard removing == nil else { return }
        removing = name
        removalFailures[name] = nil
        removalMessage = []
        defer { removing = nil }
        var lines: [String] = []
        do {
            let status = try await removalEngine.run(
                arguments: ConfigInvocation.removeBoardConnectionArguments(name: name, orphanProjects: orphanProjects)
            ) { lines.append($0) }
            guard status == 0 else {
                removalFailures[name] = lines.isEmpty ? ["yh exited \(status)."] : lines
                return
            }
            removalMessage = lines
            load()
            await refreshStatus()
        } catch {
            removalFailures[name] = ["\(error)"]
        }
    }

    // MARK: Lifecycle

    /// Terminates every running `yh`: closing the Settings window is not an Act.
    func terminate() {
        connectAnother.terminate()
        reconnectModels.values.forEach { $0.terminate() }
        operatorModels.values.forEach { $0.terminate() }
        doctorEngine.terminate()
        removalEngine.terminate()
    }

    // MARK: Private

    private func apply(_ rows: [Workspace]) {
        workspaces = rows
        let names = Set(rows.map(\.name))
        for name in reconnectModels.keys where !names.contains(name) {
            reconnectModels[name]?.terminate()
            reconnectModels[name] = nil
        }
        for name in operatorModels.keys where !names.contains(name) {
            operatorModels[name]?.terminate()
            operatorModels[name] = nil
        }
        statuses = statuses.filter { names.contains($0.key) }
        removalFailures = removalFailures.filter { names.contains($0.key) }
        for row in rows {
            if reconnectModels[row.name] == nil {
                let model = LinearInstallationModel(installation: row.name, phase: .notInstalled)
                model.onInstalled = { [weak self, weak model] in
                    self?.installFinished(connectAnother: false, name: model?.installedInstallationName ?? row.name)
                }
                reconnectModels[row.name] = model
            }
            if let existing = operatorModels[row.name] {
                existing.update(configured: row.operatorIdentity)
            } else {
                let model = OperatorIdentityModel(installation: row.name, configured: row.operatorIdentity)
                model.onSaved = { [weak self] in
                    self?.load()
                    self?.onChanged?()
                }
                operatorModels[row.name] = model
            }
        }
    }

    /// A connect or re-connect finished: reload, refresh the doctor's reading, and start the Operator
    /// choice of an installed entry that has none (connecting does not finish without it).
    private func installFinished(connectAnother isConnectAnother: Bool, name: String?) {
        load()
        let installed = isConnectAnother ? connectAnother.installedInstallationName : name
        if let installed, let model = operatorModels[installed], model.configured == nil {
            Task { await model.fetchCandidates() }
        }
        Task { await refreshStatus() }
        if isConnectAnother, let installed { onConnected?(installed) }
    }
}
