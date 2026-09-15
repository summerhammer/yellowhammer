import Domain
import Foundation

/// The machine-wide configuration file: Linear authorization, the machine default GitHub credential,
/// the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    public var linearCredential: CredentialReference
    public var gitHubCredential: CredentialReference
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]

    public init(
        linearCredential: CredentialReference,
        gitHubCredential: CredentialReference,
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry]
    ) {
        self.linearCredential = linearCredential
        self.gitHubCredential = gitHubCredential
        self.cliAdapters = cliAdapters
        self.routingTable = routingTable
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

public enum RepoRoleMatch: Hashable, Sendable {
    case any
    case role(RepoRole)
}

/// One row of the Routing Table.
public struct RoutingEntry: Equatable, Sendable {
    public var kind: Kind
    public var repoRole: RepoRoleMatch
    public var route: Route
    /// In the order they are tried.
    public var fallbacks: [Route]

    public init(kind: Kind = .any, repoRole: RepoRoleMatch = .any, route: Route, fallbacks: [Route] = []) {
        self.kind = kind
        self.repoRole = repoRole
        self.route = route
        self.fallbacks = fallbacks
    }
}

extension RoutingEntry {
    /// What identifies a row: the merge and the duplicate check both key on it.
    public struct Key: Hashable, Sendable {
        public var kind: Kind
        public var repoRole: RepoRoleMatch

        public init(kind: Kind, repoRole: RepoRoleMatch) {
            self.kind = kind
            self.repoRole = repoRole
        }
    }

    public var key: Key {
        Key(kind: kind, repoRole: repoRole)
    }
}
