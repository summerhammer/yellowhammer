import Domain
import Foundation

/// One Linear App Installation in the machine file's registry (`[board.linear.installations.<name>]`):
/// the credential, the Linear workspace it was installed into, its app user and the optional Operator
/// identity. Each Project selects exactly one by ``name``.
public struct LinearInstallation: Equatable, Sendable {
    /// The local name, the table key. Chosen by the Operator; not a Linear identifier.
    public var name: String
    public var credential: CredentialReference
    /// The Linear workspace id (`workspace`) this App Installation was installed into.
    public var workspace: BoardObjectID
    /// The App Installation's app user id (`app_user`).
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
}

/// The machine-wide configuration file: the registry of Linear App Installations (ADR-005), the machine
/// default GitHub credential, the declared CLI Adapters and the base Routing Table.
public struct MachineConfiguration: Equatable, Sendable {
    /// The registry of App Installations, in file order; zero or more.
    public var linearInstallations: [LinearInstallation]
    public var gitHubCredential: CredentialReference
    /// In file order.
    public var cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table, in file order.
    public var routingTable: [RoutingEntry]

    public init(
        linearInstallations: [LinearInstallation] = [],
        gitHubCredential: CredentialReference,
        cliAdapters: [CLIAdapterDeclaration],
        routingTable: [RoutingEntry]
    ) {
        self.linearInstallations = linearInstallations
        self.gitHubCredential = gitHubCredential
        self.cliAdapters = cliAdapters
        self.routingTable = routingTable
    }

    /// The registry entry called `name`, or nil.
    public func linearInstallation(named name: String) -> LinearInstallation? {
        linearInstallations.first { $0.name == name }
    }

    /// The App Installation `project` selects. Nil only for a Project loaded leniently
    /// (``Configuration/loadLeniently(directory:)``) whose installation name is missing from the registry.
    public func linearInstallation(for project: ProjectConfiguration) -> LinearInstallation? {
        linearInstallation(named: project.linearInstallationName)
    }

    /// The registry's only entry; nil unless there is exactly one.
    ///
    /// TEMPORARY bridge for machine-only consumers (setup, doctor Check 4, the app's Operator identity
    /// and Setup readiness) that have no Project to select an installation by. Roadmap step L3.2 deletes
    /// it. Project-scoped code must use ``linearInstallation(for:)`` instead.
    public var soleLinearInstallation: LinearInstallation? {
        linearInstallations.count == 1 ? linearInstallations[0] : nil
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
