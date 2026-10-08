/// Why a Project's Code Hosting Connection cannot give a credential. Never carries a secret.
public enum CodeHostingRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The selection names no registry entry (only reachable after a lenient load).
    case notInRegistry(connection: String)
    /// A `gh` CLI connection: it decodes, but this build cannot use it yet (roadmap S5, #391).
    case githubCLINotSupported(connection: String)

    public var description: String {
        switch self {
        case .notInRegistry(let connection):
            return "Code Hosting Connection \"\(connection)\" is not in the machine file's "
                + "[code_hosting.github.connections] registry. Connect it with "
                + "`yh setup --install-github --code-hosting-connection \(connection)`, "
                + "or select another connection for the Project."
        case .githubCLINotSupported(let connection):
            return "Code Hosting Connection \"\(connection)\" uses the gh CLI, which this build of "
                + "Yellowhammer cannot use yet. Select a Keychain token connection instead."
        }
    }
}

/// What a resolved selection gives: the connection's local name and its Keychain Credential Reference.
public struct CodeHostingCredential: Equatable, Sendable {
    public let connection: String
    public let reference: CredentialReference

    public init(connection: String, reference: CredentialReference) {
        self.connection = connection
        self.reference = reference
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
        case .githubCLI:
            throw .githubCLINotSupported(connection: name)
        case .keychainToken(let reference):
            return CodeHostingCredential(connection: name, reference: reference)
        }
    }
}
