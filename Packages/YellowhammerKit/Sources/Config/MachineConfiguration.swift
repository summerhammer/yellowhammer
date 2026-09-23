import Domain
import Foundation

/// The machine-wide configuration file: Linear authorization (client id and credential), the machine default GitHub credential,
/// the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    /// The registered Linear OAuth application's client id. Not a secret: the client secret stays
    /// behind ``linearCredential``.
    public var linearClientID: String
    public var linearCredential: CredentialReference
    /// The machine-wide Linear user assigned Waiting on You issues, when configured.
    public var linearOperator: BoardObjectID?
    public var gitHubCredential: CredentialReference
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]

    public init(
        linearClientID: String,
        linearCredential: CredentialReference,
        linearOperator: BoardObjectID? = nil,
        gitHubCredential: CredentialReference,
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry]
    ) {
        self.linearClientID = linearClientID
        self.linearCredential = linearCredential
        self.linearOperator = linearOperator
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
