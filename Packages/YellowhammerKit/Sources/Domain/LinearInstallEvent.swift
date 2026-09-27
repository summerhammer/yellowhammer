import Foundation

/// One line of `yh setup --install-linear --events json`'s NDJSON stream (roadmap P17.6 slice (b);
/// spec: board-projection/install-the-linear-app). Lives in Domain, not Engine or EngineCommand, so
/// `Yellowhammer.app` can decode it without linking Engine (the app is a shell, never a host).
public enum LinearInstallEvent: Equatable, Sendable {
    /// The admin statement, shown before the browser opens.
    case adminStatement(text: String)
    /// All three fixed ports are busy; the browser was never opened.
    case portsBusy(ports: [PortRow], text: String)
    case browserOpened(url: String)
    case awaitingApproval
    case installed(workspaceName: String)
    /// The attempt did not end in an installation, for `reason`, with Linear's or setup's own text.
    case failed(reason: FailureReason, text: String)

    /// One busy port and its holder, when known — a Domain-owned mirror of `EngineCommand`'s
    /// `PortHolder` (ADR-001: no adapter or EngineCommand type crosses this boundary).
    public struct PortRow: Equatable, Sendable, Codable {
        public let port: Int
        public let pid: Int32?
        public let command: String?

        public init(port: Int, pid: Int32?, command: String?) {
            self.port = port
            self.pid = pid
            self.command = command
        }
    }

    public enum FailureReason: String, Equatable, Sendable, Codable {
        case cancelled
        case notCompleted
        case differentWorkspace
        case portsBusy
        case other
    }
}

extension LinearInstallEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case event, text, ports, url, workspaceName, reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case "adminStatement":
            self = .adminStatement(text: try container.decode(String.self, forKey: .text))
        case "portsBusy":
            self = .portsBusy(
                ports: try container.decode([PortRow].self, forKey: .ports),
                text: try container.decode(String.self, forKey: .text)
            )
        case "browserOpened":
            self = .browserOpened(url: try container.decode(String.self, forKey: .url))
        case "awaitingApproval":
            self = .awaitingApproval
        case "installed":
            self = .installed(workspaceName: try container.decode(String.self, forKey: .workspaceName))
        case "failed":
            self = .failed(
                reason: try container.decode(FailureReason.self, forKey: .reason),
                text: try container.decode(String.self, forKey: .text)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container, debugDescription: "unknown LinearInstallEvent \"\(event)\""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .adminStatement(let text):
            try container.encode("adminStatement", forKey: .event)
            try container.encode(text, forKey: .text)
        case .portsBusy(let ports, let text):
            try container.encode("portsBusy", forKey: .event)
            try container.encode(ports, forKey: .ports)
            try container.encode(text, forKey: .text)
        case .browserOpened(let url):
            try container.encode("browserOpened", forKey: .event)
            try container.encode(url, forKey: .url)
        case .awaitingApproval:
            try container.encode("awaitingApproval", forKey: .event)
        case .installed(let workspaceName):
            try container.encode("installed", forKey: .event)
            try container.encode(workspaceName, forKey: .workspaceName)
        case .failed(let reason, let text):
            try container.encode("failed", forKey: .event)
            try container.encode(reason, forKey: .reason)
            try container.encode(text, forKey: .text)
        }
    }

    /// One NDJSON line: the compact single-line JSON encoding this stream's readers expect.
    public func ndjsonLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LinearInstallEventError.couldNotEncode
        }
        return json
    }
}

public enum LinearInstallEventError: Error, Sendable {
    case couldNotEncode
}
