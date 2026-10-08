import Foundation

/// Machine registry report consumed by Settings. Identity is read live and omitted when unavailable.
public struct CodeHostingConnectionsReport: Codable, Equatable, Sendable {
    public struct Connection: Codable, Equatable, Sendable {

        public var name: String
        public var type: CodeHostingConnectionKind
        public var identity: String?
        public var state: CodeHostingConnectionState
        public var reason: String?
        public var projects: [String]

        public init(name: String, type: CodeHostingConnectionKind, identity: String? = nil,
                    state: CodeHostingConnectionState, reason: String? = nil,
                    projects: [String]) {
            self.name = name
            self.type = type
            self.identity = identity
            self.state = state
            self.reason = reason
            self.projects = projects
        }
    }

    /// Whether connecting the gh CLI is offered: `available` only when `yh` found `gh` logged in (then `login`
    /// names its active account); otherwise `reason` is `yh`'s own words for why not.
    public struct GitHubCLIOffer: Codable, Equatable, Sendable {
        public var available: Bool
        public var login: String?
        public var reason: String?

        public init(available: Bool, login: String? = nil, reason: String? = nil) {
            self.available = available
            self.login = login
            self.reason = reason
        }
    }

    public var connections: [Connection]
    /// The gh CLI offer; absent in a line from a `yh` that predates it.
    public var gitHubCLI: GitHubCLIOffer?

    private enum CodingKeys: String, CodingKey {
        case connections
        case gitHubCLI = "githubCLI"
    }

    public init(connections: [Connection], gitHubCLI: GitHubCLIOffer? = nil) {
        self.connections = connections
        self.gitHubCLI = gitHubCLI
    }

    public func encodeLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    public static func decodeLastLine(_ lines: [String]) -> Self? {
        guard let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(line.utf8))
    }
}

public enum CodeHostingConnectionKind: String, Codable, Sendable { case gh, keychain }
public enum CodeHostingConnectionState: String, Codable, Sendable { case ok, refused }
