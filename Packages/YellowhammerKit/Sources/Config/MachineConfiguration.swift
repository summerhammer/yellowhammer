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
    /// The configured `description_budget`, nil when unset (``DescriptionBudget/defaultValue`` applies). At
    /// least 1 once loaded; the ceiling is the board's, so ``descriptionBudget(limit:)`` checks it.
    public var descriptionBudget: Int?
    /// Where `description_budget` was read, for an error found later. Nil for an installation built in
    /// code; not part of equality.
    public var descriptionBudgetSource: ConfigurationSource?

    public init(
        name: String,
        credential: CredentialReference,
        workspace: BoardObjectID,
        appUser: BoardObjectID,
        operatorIdentity: BoardObjectID? = nil,
        descriptionBudget: Int? = nil,
        descriptionBudgetSource: ConfigurationSource? = nil
    ) {
        self.name = name
        self.credential = credential
        self.workspace = workspace
        self.appUser = appUser
        self.operatorIdentity = operatorIdentity
        self.descriptionBudget = descriptionBudget
        self.descriptionBudgetSource = descriptionBudgetSource
    }

    public static func == (lhs: LinearInstallation, rhs: LinearInstallation) -> Bool {
        lhs.name == rhs.name && lhs.credential == rhs.credential && lhs.workspace == rhs.workspace
            && lhs.appUser == rhs.appUser && lhs.operatorIdentity == rhs.operatorIdentity
            && lhs.descriptionBudget == rhs.descriptionBudget
    }

    /// The description budget this Board Connection's board enforces: ``descriptionBudget`` or the
    /// default, checked against the ceiling of the board's `limit`, which the board's adapter supplies.
    /// A value above the ceiling is refused as the `description_budget` key, naming the ceiling.
    public func descriptionBudget(limit: BoardDescriptionLimit) throws(ConfigurationError) -> DescriptionBudget {
        do {
            return try DescriptionBudget(configured: descriptionBudget, limit: limit)
        } catch {
            let reason: ConfigurationError.Reason
            switch error {
            case .belowOne(let value):
                reason = .notPositive(Int64(value))
            case .aboveCeiling(let value, let ceiling):
                reason = .aboveDescriptionBudgetCeiling(value: value, ceiling: ceiling, limit: limit)
            }
            throw ConfigurationError(
                file: descriptionBudgetSource?.file ?? "config.toml", line: descriptionBudgetSource?.line ?? 1,
                key: TOMLKey.path(TOMLKey.path("board.linear.connections", name), "description_budget"),
                reason: reason
            )
        }
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

/// A line of a configuration file.
public struct ConfigurationSource: Sendable {
    public let file: String
    /// 1-based.
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// The machine-wide configuration file: the registry of Linear Board Connections (ADR-005), the registry of
/// Code Hosting Connections, the Operator-declared Repo Roles, the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    /// The registry of Board Connections, in file order; zero or more.
    public var linearInstallations: [LinearInstallation]
    /// The registry of Code Hosting Connections, in file order; zero or more.
    public var codeHostingConnections: [CodeHostingConnection]
    /// The Repo Roles the Operator declared (`repo_roles`), beyond the built-in ``RepoRole/standard`` ones, in
    /// file order. Non-validating: the registry feeds the pickers, and a Repo or Routing Entry naming an
    /// undeclared Repo Role still loads.
    public var repoRoles: [RepoRole]
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]

    public init(
        linearInstallations: [LinearInstallation] = [],
        codeHostingConnections: [CodeHostingConnection] = [],
        repoRoles: [RepoRole] = [],
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry]
    ) {
        self.linearInstallations = linearInstallations
        self.codeHostingConnections = codeHostingConnections
        self.repoRoles = repoRoles
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
