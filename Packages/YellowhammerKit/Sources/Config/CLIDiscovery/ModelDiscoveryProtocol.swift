import Foundation

/// Only control-plane requests are allowed here: no Claude user frame or Codex thread/turn request.
struct ModelDiscoveryProtocol {
    enum Vendor: String, Sendable {
        case claude, codex, agy

        var arguments: [String] {
            switch self {
            case .claude:
                return [
                    "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--no-session-persistence"
                ]
            case .codex: return ["app-server"]
            case .agy: return ["models"]
            }
        }
    }

    enum Step {
        case waiting
        case send(String)
        case complete([AgentModel])
        case failed(String)
    }

    let vendor: Vendor
    private var requestID = 1
    private var models: [AgentModel] = []
    private var cursors: Set<String> = []

    var initialInput: String {
        switch vendor {
        case .claude:
            return #"{"type":"control_request","request_id":"models","request":{"subtype":"initialize"}}"# + "\n"
        case .codex:
            return #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"yellowhammer","version":"1"}}}"#
                + "\n"
        case .agy: return ""
        }
    }

    mutating func receive(_ line: String) -> Step {
        guard let object = Self.objects(in: line).first else { return .waiting }
        switch vendor {
        case .claude: return claude(object)
        case .codex: return codex(object)
        case .agy: return .waiting
        }
    }

    private func claude(_ object: [String: Any]) -> Step {
        guard object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == "models" else { return .waiting }
        guard response["subtype"] as? String == "success" else {
            return .failed("Claude Code initialize failed: \(Self.errorDescription(response["error"]))")
        }
        guard let payload = response["response"] as? [String: Any],
              let rows = payload["models"] as? [[String: Any]],
              let choices = Self.models(rows, identifier: "value") else {
            return .failed("Claude Code returned a malformed initialize model list.")
        }
        return .complete(choices)
    }

    private mutating func codex(_ object: [String: Any]) -> Step {
        guard Self.id(object["id"]) == String(requestID) else { return .waiting }
        if let error = object["error"] {
            return .failed("Codex returned a protocol error: \(Self.errorDescription(error))")
        }
        guard let result = object["result"] as? [String: Any] else {
            return .failed("Codex returned a malformed protocol response.")
        }
        if requestID == 1 {
            requestID = 2
            return .send(#"{"method":"initialized"}"# + "\n" + modelListRequest(cursor: nil))
        }
        guard let rows = result["data"] as? [[String: Any]],
              let choices = Self.models(rows, identifier: "model", excludeHidden: true) else {
            return .failed("Codex returned a malformed model/list response.")
        }
        models.append(contentsOf: choices)
        guard let cursor = result["nextCursor"], !(cursor is NSNull) else { return .complete(models) }
        guard let cursor = cursor as? String, !cursor.isEmpty else {
            return .failed("Codex returned a malformed pagination cursor.")
        }
        guard cursors.insert(cursor).inserted else { return .failed("Codex repeated a model-list pagination cursor.") }
        guard requestID < 101 else { return .failed("Codex model discovery exceeded the 100-page limit.") }
        requestID += 1
        return .send(modelListRequest(cursor: cursor))
    }

    private func modelListRequest(cursor: String?) -> String {
        let parameters: [String: Any] = ["cursor": cursor as Any? ?? NSNull(), "limit": 100, "includeHidden": false]
        let request: [String: Any] = ["id": requestID, "method": "model/list", "params": parameters]
        // These values are all JSON primitives. Serializing protects opaque cursors from interpolation.
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    static func objects(in output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    static func id(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? NSNumber)?.stringValue
    }

    static func models(_ rows: [[String: Any]], identifier: String, excludeHidden: Bool = false) -> [AgentModel]? {
        var choices: [AgentModel] = []
        var seen: Set<String> = []
        for row in rows {
            if excludeHidden, row["hidden"] as? Bool == true { continue }
            guard let id = row[identifier] as? String, !id.isEmpty else { return nil }
            let label = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let choice = AgentModel(id: id, label: label)
            if seen.insert(id).inserted { choices.append(choice) }
        }
        return choices
    }

    private static func errorDescription(_ error: Any?) -> String {
        if let message = error as? String { return String(message.prefix(1_000)) }
        if let object = error as? [String: Any], let message = object["message"] as? String {
            return String(message.prefix(1_000))
        }
        return "the installed CLI rejected the model-list request"
    }
}
