import Foundation

/// A CLI model as the vendor presents it. Its identifier is the exact value written into a Route.
public struct AgentModel: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Result of one user-requested, bounded model discovery operation.
public enum AgentModelDiscoveryResult: Equatable, Sendable {
    case live(models: [AgentModel])
    case unsupported(String)
    case failed(String)
}

/// Reads the installed vendor CLI's model list without starting an agent task, caching, or watching.
public enum AgentModelDiscovery {
    public static let timeout: Duration = .seconds(8)
    public static let maximumOutputBytes = 512 * 1024

    /// The CLI has an eight-second total budget, including all pages. Resolving a missing executable's
    /// login-shell PATH has a separate five-second budget. Process cleanup adds at most one second.
    public static func discover(
        cli: String,
        executable: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> AgentModelDiscoveryResult {
        guard let vendor = ModelDiscoveryProtocol.Vendor(rawValue: cli) else {
            return .unsupported("Model discovery is not supported for \(cli).")
        }
        if Task.isCancelled { return .failed("Model discovery was cancelled.") }
        var resolvedEnvironment = environment
        if executable == nil {
            switch await LoginShellPATH.read(timeout: .seconds(5), environment: environment) {
            case .path(let path): resolvedEnvironment["PATH"] = path
            case .failed(let failure): return .failed(failure.description)
            }
        }
        // Nested-session detection is irrelevant to the SDK's task-free initialize request.
        resolvedEnvironment.removeValue(forKey: "CLAUDECODE")
        return await ModelDiscoveryProcess.run(
            vendor: vendor, executable: executable ?? cli, environment: resolvedEnvironment
        )
    }

    /// Parses a Codex app-server model/list response, using `model` rather than the opaque row id.
    public static func parseCodexResponse(_ output: String, requestID: String = "model-list") -> [AgentModel]? {
        for object in ModelDiscoveryProtocol.objects(in: output) {
            guard ModelDiscoveryProtocol.id(object["id"]) == requestID else { continue }
            if let result = object["result"] as? [String: Any],
               let values = result["data"] as? [[String: Any]] {
                return ModelDiscoveryProtocol.models(values, identifier: "model", excludeHidden: true)
            }
        }
        return nil
    }

    /// Parses Claude Code's SDK initialize envelope. The request id belongs to the nested response.
    public static func parseClaudeInitializeResponse(_ output: String, requestID: String = "models") -> [AgentModel]? {
        for object in ModelDiscoveryProtocol.objects(in: output) {
            guard object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  response["request_id"] as? String == requestID,
                  response["subtype"] as? String == "success",
                  let payload = response["response"] as? [String: Any],
                  let values = payload["models"] as? [[String: Any]] else { continue }
            return ModelDiscoveryProtocol.models(values, identifier: "value")
        }
        return nil
    }

    /// Antigravity emits exactly `identifier<TAB>label` rows. An empty list is valid; prose is not a model.
    public static func parseAntigravityModels(_ output: String) -> [AgentModel]? {
        var models: [AgentModel] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2 else { return nil }
            let id = String(columns[0]).trimmingCharacters(in: .whitespaces)
            let label = String(columns[1]).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !label.isEmpty else { return nil }
            models.append(AgentModel(id: id, label: label))
        }
        return models
    }
}
