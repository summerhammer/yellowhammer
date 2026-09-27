import Config
import Domain
import Engine
import Foundation
import LinearAdapter

/// Builds the Board Port for one resolved Project. The only place a board adapter is wired (MB2).
///
/// The Linear identity is the Installation (ADR-005), machine-wide (ADR-001, Invariant 4): its tokens
/// live in the Keychain behind the machine-wide file's credential reference, refreshed under a
/// machine-wide `MachineLock`; only the Linear project comes from the Project's own file. Construction
/// never touches the Keychain (no eager read): a missing or revoked Installation surfaces as
/// `.notAuthenticated` from the first Linear call the adapter makes, inside the Act — never from
/// binding itself.
enum BoardBinding {
    static func board(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> any Board {
        makeLinearAdapter(
            machine: machine, linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory
        )
    }

    static func provisioning(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> any BoardProvisioning {
        makeLinearAdapter(
            machine: machine, linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory
        )
    }

    /// The Board Port as one Act holds it (writing and provisioning together), from the same adapter.
    static func actBoard(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ActBoard {
        let adapter = makeLinearAdapter(
            machine: machine, linearProjectID: project.linearProject, credentials: store, homeDirectory: homeDirectory
        )
        return ActBoard(reading: adapter, writing: adapter, provisioning: adapter)
    }

    /// Binds directly from an already-resolved Linear project id, for `yh setup`/`yh doctor`, which
    /// have no `ProjectConfiguration` yet. `linearProjectID` may be `""` for the workspace-level calls
    /// (`workspaceMembers()`, `teams()`, project creation): those are not scoped to a Linear project, so
    /// the binding's own linearProjectID is irrelevant to them.
    static func provisioning(
        machine: MachineConfiguration,
        linearProjectID: String,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> any BoardProvisioning {
        makeLinearAdapter(
            machine: machine, linearProjectID: linearProjectID, credentials: store, homeDirectory: homeDirectory
        )
    }

    private static func makeLinearAdapter(
        machine: MachineConfiguration,
        linearProjectID: String,
        credentials store: KeychainCredentialStore,
        homeDirectory: URL
    ) -> LinearAdapter {
        let installationStore = LinearInstallationStore(
            reference: machine.linearCredential,
            keychain: store,
            machineLock: MachineLock(fileURL: MachineLock.defaultFileURL(homeDirectory: homeDirectory))
        )
        return LinearAdapter(linearProjectID: linearProjectID, tokenStore: installationStore.tokenStore)
    }
}
