/// Why a Project's Code Hosting Connection cannot give a credential. Never carries a secret.
public enum CodeHostingRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The selection names no registry entry (only reachable after a lenient load).
    case notInRegistry(connection: String)

    public var description: String {
        switch self {
        case .notInRegistry(let connection):
            return "Code Hosting Connection \"\(connection)\" is not in the machine file's "
                + "[code_hosting.github.connections] registry. Connect it with "
                + "`yh config connect-code-hosting \(connection) --token-stdin`, "
                + "or select another connection for the Project."
        }
    }
}

/// What a resolved selection gives: the connection's local name and how it authenticates.
public enum CodeHostingCredential: Equatable, Sendable {
    /// A token held in the macOS Keychain under this Credential Reference.
    case keychainToken(connection: String, reference: CredentialReference)
    /// The Operator's own `gh` CLI, which holds the token; Yellowhammer holds none. `executable` is the
    /// declared path, or nil when `gh` is looked up at the time of use.
    case githubCLI(connection: String, executable: String?)

    /// The connection's local name.
    public var connection: String {
        switch self {
        case .keychainToken(let connection, _), .githubCLI(let connection, _):
            connection
        }
    }
}

extension MachineConfiguration {
    /// The one resolver: Project → its selected connection → its credential. Every reader (land, the
    /// narrative scrub, `yh doctor`, setup, `yh project remove`) goes through it.
    public func codeHostingCredential(
        for project: ProjectConfiguration
    ) throws(CodeHostingRefusal) -> CodeHostingCredential {
        try codeHostingCredential(connectionNamed: project.codeHostingConnectionName)
    }

    /// The same resolution for a connection named directly (setup's `--code-hosting-connection`).
    public func codeHostingCredential(
        connectionNamed name: String
    ) throws(CodeHostingRefusal) -> CodeHostingCredential {
        guard let connection = codeHostingConnection(named: name) else {
            throw .notInRegistry(connection: name)
        }
        switch connection.kind {
        case .githubCLI(let executable):
            return .githubCLI(connection: name, executable: executable)
        case .keychainToken(let reference):
            return .keychainToken(connection: name, reference: reference)
        }
    }
}
