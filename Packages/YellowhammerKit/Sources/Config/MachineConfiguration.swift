import Domain
import Foundation

/// The machine-wide configuration file: the Linear App Installation (ADR-005), the machine default
/// GitHub credential, the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    public var linearCredential: CredentialReference
    /// The Installation's workspace id (`[linear].workspace`), nil until installed (P17.6 writes it).
    public var linearWorkspace: BoardObjectID?
    /// The Installation's app user id (`[linear].app_user`), nil until installed.
    public var linearAppUser: BoardObjectID?
    public var gitHubCredential: CredentialReference
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]
    /// The Operator identity's Linear user id (`[linear].operator`), nil when unconfigured or configured
    /// empty — a missing Operator identity is never a load-time validation failure (Operator Identity
    /// Ruling — 2026-09-23).
    public var operatorIdentity: BoardObjectID?

    public init(
        linearCredential: CredentialReference,
        linearWorkspace: BoardObjectID? = nil,
        linearAppUser: BoardObjectID? = nil,
        gitHubCredential: CredentialReference,
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry],
        operatorIdentity: BoardObjectID? = nil
    ) {
        self.linearCredential = linearCredential
        self.linearWorkspace = linearWorkspace
        self.linearAppUser = linearAppUser
        self.gitHubCredential = gitHubCredential
        self.cliAdapters = cliAdapters
        self.routingTable = routingTable
        self.operatorIdentity = operatorIdentity
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
