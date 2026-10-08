import Domain
import Foundation

/// One Linear Board Connection in the machine file's registry (`[board.linear.connections.<name>]`):
/// the credential, the Linear workspace it was installed into, its Yellowhammer identity and the optional Operator
/// identity. Each Project selects exactly one by ``name``.
public struct LinearInstallation: Equatable, Sendable {
    /// The local name, the table key. Chosen by the Operator; not a Linear identifier.
    public var name: String
    public var credential: CredentialReference
    /// The Linear workspace id (`workspace`) this Board Connection was installed into.
    public var workspace: BoardObjectID
    /// The Board Connection's Yellowhammer identity id (`yellowhammer_identity`).
    public var appUser: BoardObjectID
    /// The Operator identity's Linear user id (`operator`), nil when unconfigured or configured
    /// empty — a missing Operator identity is never a load-time validation failure (Operator Identity
    /// Ruling — 2026-09-23).
    public var operatorIdentity: BoardObjectID?

    public init(
        name: String,
        credential: CredentialReference,
        workspace: BoardObjectID,
        appUser: BoardObjectID,
        operatorIdentity: BoardObjectID? = nil
    ) {
        self.name = name
        self.credential = credential
        self.workspace = workspace
        self.appUser = appUser
        self.operatorIdentity = operatorIdentity
    }

    /// Whether `name` is a valid local name: `^[a-z0-9][a-z0-9_-]*$`. Setup proposes only names that pass;
    /// the TOML decoder does not enforce it, so a quoted name that fails still loads.
    public static func isValidLocalName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLocalNameAlphanumeric(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLocalNameAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    private static func isLocalNameAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// The machine-wide configuration file: the registry of Linear Board Connections (ADR-005), the registry of
/// Code Hosting Connections, the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    /// The registry of Board Connections, in file order; zero or more.
    public var linearInstallations: [LinearInstallation]
    /// The registry of Code Hosting Connections, in file order; zero or more.
    public var codeHostingConnections: [CodeHostingConnection]
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]

    public init(
        linearInstallations: [LinearInstallation] = [],
        codeHostingConnections: [CodeHostingConnection] = [],
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry]
    ) {
        self.linearInstallations = linearInstallations
        self.codeHostingConnections = codeHostingConnections
        self.cliAdapters = cliAdapters
        self.routingTable = routingTable
    }

    /// The registry entry called `name`, or nil.
    public func linearInstallation(named name: String) -> LinearInstallation? {
        linearInstallations.first { $0.name == name }
    }

    /// The Board Connection `project` selects. Nil only for a Project loaded leniently
    /// (``Configuration/loadLeniently(directory:)``) whose installation name is missing from the registry.
    public func linearInstallation(for project: ProjectConfiguration) -> LinearInstallation? {
        linearInstallation(named: project.linearInstallationName)
    }

    /// The registry entry called `name`, or nil.
    public func codeHostingConnection(named name: String) -> CodeHostingConnection? {
        codeHostingConnections.first { $0.name == name }
    }

    /// The Code Hosting Connection `project` selects. Nil only for a Project loaded leniently
    /// (``Configuration/loadLeniently(directory:)``) whose connection name is missing from the registry.
    public func codeHostingConnection(for project: ProjectConfiguration) -> CodeHostingConnection? {
        codeHostingConnection(named: project.codeHostingConnectionName)
    }
}

extension MachineConfiguration {
    /// `~/.config/yellowhammer/config.toml` under the given home directory.
    public static func defaultFileURL(homeDirectory: URL) -> URL {
        homeDirectory.appending(components: ".config", "yellowhammer", "config.toml", directoryHint: .notDirectory)
    }

    public static func load(contentsOf url: URL) throws(ConfigurationError) -> MachineConfiguration {
        let file = url.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigurationError(file: file, line: 1, key: nil, reason: .unreadable(error.localizedDescription))
        }
        return try parse(text, file: file)
    }

    public static func parse(_ text: String, file: String) throws(ConfigurationError) -> MachineConfiguration {
        let root = try TOMLParser.parse(text, file: file)
        return try MachineConfigurationDecoder(file: file).decode(root)
    }
}

/// A reference to a credential held elsewhere, such as `keychain:linear`. Never the secret itself.
public struct CredentialReference: Hashable, Sendable {
    public let rawValue: String

    /// Fails when the reference is empty.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

public struct CLIAdapterDeclaration: Equatable, Sendable {
    public var name: String
    public var executable: String?

    public init(name: String, executable: String? = nil) {
        self.name = name
        self.executable = executable
    }
}
