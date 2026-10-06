import Config
import Domain
import Engine
import Foundation
import LinearAdapter

/// Builds the Board Port for one resolved Project. The only place a board adapter is wired (MB2).
///
/// The Linear identity is the Project's own Board Connection (ADR-005), resolved from the machine
/// file's registry by the name its `[board.linear] installation` key gives: its tokens live in the
/// Keychain behind that installation's credential reference, refreshed under that
/// installation's own `MachineLock`; only the Linear project comes from the
/// Project's own file. Construction never touches the Keychain (no eager read): a missing or revoked
/// Installation surfaces as `.notAuthenticated` from the first Linear call the adapter makes, inside the
/// Act — never from binding itself. A Project naming an installation the registry lacks cannot be bound:
/// that is ``BoardBindingError/installationMissing(project:installation:)``.
enum BoardBinding {
    static func board(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> any Board {
        makeLinearAdapter(
            installation: try installation(machine: machine, project: project),
            linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory
        )
    }

    static func provisioning(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> any BoardProvisioning {
        makeLinearAdapter(
            installation: try installation(machine: machine, project: project),
            linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory
        )
    }

    /// The Board Port as one Act holds it (writing and provisioning together), from the same adapter.
    static func actBoard(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ActBoard {
        let resolved = try installation(machine: machine, project: project)
        let label = AppInstallationLabel(name: resolved.name, workspace: resolved.workspace)
        let refreshes = AppInstallationTokenRefreshLog(installation: label)
        let adapter = makeLinearAdapter(
            installation: resolved,
            linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory,
            refreshLog: refreshes
        )
        return ActBoard(
            reading: adapter, writing: adapter, provisioning: adapter, tokenRefreshes: refreshes, installation: label
        )
    }

    /// Binds directly from an already-resolved Board Connection and Linear project id, for
    /// `yh setup`/`yh doctor`, which have no `ProjectConfiguration` yet. `linearProjectID` may be `""` for
    /// the workspace-level calls (`workspaceMembers()`, `teams()`, project creation): those are not scoped
    /// to a Linear project, so the binding's own linearProjectID is irrelevant to them.
    static func provisioning(
        installation: LinearInstallation,
        linearProjectID: String,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> any BoardProvisioning {
        makeLinearAdapter(
            installation: installation, linearProjectID: linearProjectID, credentials: store,
            homeDirectory: homeDirectory
        )
    }

    /// The store holding `installation`'s tokens: its credential reference, the Keychain and the
    /// refresh lock keyed by the installation's name.
    static func installationStore(
        for installation: LinearInstallation,
        credentials store: KeychainCredentialStore,
        homeDirectory: URL
    ) -> LinearInstallationStore {
        LinearInstallationStore(
            reference: installation.credential,
            keychain: store,
            machineLock: MachineLock(
                fileURL: MachineLock.defaultFileURL(homeDirectory: homeDirectory, installation: installation.name)
            )
        )
    }

    /// The Linear workspace of the Board Connection `project` selects: what a Journal created for the
    /// Project records.
    static func workspace(
        machine: MachineConfiguration, project: ProjectConfiguration
    ) throws(BoardBindingError) -> BoardObjectID {
        try installation(machine: machine, project: project).workspace
    }

    private static func installation(
        machine: MachineConfiguration, project: ProjectConfiguration
    ) throws(BoardBindingError) -> LinearInstallation {
        guard let installation = machine.linearInstallation(for: project) else {
            throw .installationMissing(project: project.id, installation: project.linearInstallationName)
        }
        return installation
    }

    private static func makeLinearAdapter(
        installation: LinearInstallation,
        linearProjectID: String,
        credentials store: KeychainCredentialStore,
        homeDirectory: URL,
        refreshLog: AppInstallationTokenRefreshLog? = nil
    ) -> LinearAdapter {
        let installationStore = installationStore(for: installation, credentials: store, homeDirectory: homeDirectory)
        return LinearAdapter(
            linearProjectID: linearProjectID, tokenStore: installationStore.tokenStore, refreshLog: refreshLog
        )
    }
}

/// Why a Project's board could not be bound.
enum BoardBindingError: Error, Equatable, CustomStringConvertible {
    /// The Project's `[board.linear] installation` names no entry in the machine file's registry.
    case installationMissing(project: ProjectID, installation: String)

    var description: String {
        switch self {
        case .installationMissing(let project, let installation):
            "Project \(project.rawValue) names Linear Board Connection \"\(installation)\", "
                + "which config.toml does not declare"
        }
    }
}
