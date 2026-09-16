import Config
import Domain
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
