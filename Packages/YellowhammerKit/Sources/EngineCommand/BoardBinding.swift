import Config
import Domain
import Engine
import LinearAdapter

/// Builds the Board Port for one resolved Project. The only place a board adapter is wired (MB2).
///
/// The Linear identity is machine-wide (ADR-001, Invariant 4): the client id and secret come from the
/// machine-wide file and the Keychain; only the Linear project comes from the Project's own file.
enum BoardBinding {
    static func board(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) throws(BoardBindingError) -> any Board {
        try makeLinearAdapter(machine: machine, project: project, credentials: store)
    }

    static func provisioning(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) throws(BoardBindingError) -> any BoardProvisioning {
        try makeLinearAdapter(machine: machine, project: project, credentials: store)
    }

    /// The Board Port as one Act holds it (writing and provisioning together), from the same adapter.
    static func actBoard(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) throws(BoardBindingError) -> ActBoard {
        let adapter = try makeLinearAdapter(machine: machine, project: project, credentials: store)
        return ActBoard(reading: adapter, writing: adapter, provisioning: adapter)
    }

    /// Binds directly from an already-resolved Linear project id and client secret, for `yh setup`,
    /// which already holds its own secret through its credentials seam. `linearProjectID` may be `""`
    /// for the workspace-level calls (`workspaceMembers()`, `teams()`, project creation): those are not
    /// scoped to a Linear project, so the binding's own linearProjectID is irrelevant to them.
    static func provisioning(
        machine: MachineConfiguration, linearProjectID: String, clientSecret: String
    ) -> any BoardProvisioning {
        LinearAdapter(
            linearProjectID: linearProjectID,
            credentials: LinearCredentials(clientID: machine.linearClientID, clientSecret: clientSecret)
        )
    }

    private static func makeLinearAdapter(
        machine: MachineConfiguration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore
    ) throws(BoardBindingError) -> LinearAdapter {
        let secret: String
        do {
            secret = try store.read(machine.linearCredential)
        } catch {
            throw BoardBindingError(credential: machine.linearCredential, cause: error)
        }
        return LinearAdapter(
            linearProjectID: project.linearProject,
            credentials: LinearCredentials(clientID: machine.linearClientID, clientSecret: secret)
        )
    }
}

/// The Linear client secret could not be read from where the machine-wide file points.
struct BoardBindingError: Error, Equatable, Sendable, CustomStringConvertible {
    let credential: CredentialReference
    let cause: KeychainError

    var description: String {
        "The Linear client secret \(credential.rawValue) could not be read: \(cause). "
            + "Store it with `security add-generic-password -U -s \(KeychainCredentialStore.service) "
            + "-a <account> -w <client-secret>`."
    }
}
