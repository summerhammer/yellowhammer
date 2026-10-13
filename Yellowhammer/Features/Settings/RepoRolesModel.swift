import Config
import Domain
import Foundation
import Observation

/// The machine-wide "Repo Roles" pane's model. Not Project-scoped: the Repo Roles an Operator declares live in
/// `config.toml`'s `repo_roles`, beside the standard ones every Mac offers. Lists the standard Repo Roles and the
/// declared ones, each with the Projects whose Repos or routing overrides name it, and declares or removes one
/// through the loader, as the Agent CLIs pane does — creating `config.toml` when it does not exist yet.
///
/// The loader is the single validator, run when the result is saved. The registry only feeds pickers, so
/// removing a Repo Role that is in use is allowed: it stops being offered, and a Repo or Routing Entry still
/// naming it keeps working. The app never probes, discovers or writes anything but `config.toml`.
@MainActor
@Observable
final class RepoRolesModel {
    let directory: URL
    let file: URL

    /// One Repo Role the pane lists.
    struct Row: Identifiable {
        let name: String
        var id: String { name }
        let isStandard: Bool
        /// The names of the Projects where a Repo has this Repo Role or a routing override names it.
        let usedBy: [String]
        /// Whether a base Routing Table entry names this Repo Role.
        let namedInBaseTable: Bool
    }

    /// The standard Repo Roles, then the declared ones; nil until `config.toml` has been read.
    private(set) var rows: [Row]?
    /// `config.toml`'s text as last loaded, what a change is saved against; nil while it does not exist.
    private(set) var originalText: String?
    /// The loaded machine file, carried through so a change re-renders it whole.
    private(set) var machine: MachineConfiguration?
    /// The Projects that loaded, which say where each Repo Role is used.
    private(set) var projects: [ProjectConfiguration] = []
    /// Set when `config.toml` exists but could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?
    /// Set when `config.toml` does not exist at all: declaring a Repo Role creates it.
    private(set) var configMissing = false
    /// Why the last ``declare(name:)`` did not write; cleared by a successful load or declaration.
    private(set) var declareFailure: String?
    /// Why the last ``remove(name:)`` of each Repo Role did not write, keyed by its name; cleared by a
    /// successful load.
    private(set) var removeFailures: [String: String] = [:]

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        file = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        load()
    }

    /// Reloads the declared Repo Roles from `config.toml` and the Projects beside it.
    func load() {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            clear()
            configMissing = true
            apply(machine: .unconfigured, projects: [])
            return
        }
        configMissing = false
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            clear()
            loadFailure = "\(file.path(percentEncoded: false)) could not be read: \(error.localizedDescription)"
            return
        }
        do {
            let configuration = try Configuration.load(directory: directory, reading: file, as: text)
            originalText = text
            loadFailure = nil
            declareFailure = nil
            removeFailures = [:]
            apply(machine: configuration.machine, projects: configuration.projects)
        } catch {
            clear()
            loadFailure = error.description
        }
    }

    /// Declares `name` (trimmed) and writes `config.toml` through the loader, then reloads. A name that cannot
    /// be declared is refused before anything is written.
    func declare(name: String) {
        guard let machine else { return }
        if let problem = machine.declarationProblem(forRepoRoleNamed: name) {
            declareFailure = problem
            return
        }
        do {
            try save(machine.declaring(repoRole: name))
            load()
        } catch {
            declareFailure = error.description
        }
    }

    /// Removes the declared Repo Role `name` and writes `config.toml` through the loader, then reloads.
    func remove(name: String) {
        guard let machine else { return }
        do {
            try save(machine.removing(repoRole: RepoRole(rawValue: name)))
            load()
        } catch {
            removeFailures[name] = error.description
        }
    }

    /// Reloads when the app becomes active again: nothing here is mid-edit, the typed name lives in the view.
    func reloadIfIdle() {
        load()
    }

    private func save(_ updated: MachineConfiguration) throws(ConfigurationEditError) {
        try Configuration.save(
            updated.renderedTOML(routingTable: updated.routingTable.map(RoutingEntryDraft.init)),
            to: file, in: directory, replacing: originalText
        )
    }

    private func apply(machine: MachineConfiguration, projects: [ProjectConfiguration]) {
        self.machine = machine
        self.projects = projects
        // Not `offeredRepoRoles(with:)`: a Repo Role only a Project names is not a declaration.
        rows = machine.offeredRepoRoles.map { role in
            Row(
                name: role.rawValue,
                isStandard: role.isStandard,
                usedBy: machine.projectsUsing(repoRole: role, in: projects),
                namedInBaseTable: machine.baseRoutingTableNames(repoRole: role)
            )
        }
    }

    private func clear() {
        originalText = nil
        machine = nil
        rows = nil
        projects = []
        loadFailure = nil
        declareFailure = nil
        removeFailures = [:]
    }
}
