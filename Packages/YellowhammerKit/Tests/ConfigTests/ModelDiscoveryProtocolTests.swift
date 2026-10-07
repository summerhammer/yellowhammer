@testable import Config
import Foundation
import Testing

@Suite("Model discovery pagination protocol")
struct ModelDiscoveryProtocolTests {
    @Test("Codex's 100-page boundary completes only when the final page has no cursor", arguments: [false, true])
    func pageLimit(hasNextPage: Bool) throws {
        var state = try initializedCodex()
        let expected = (1...100).map { AgentModel(id: "model-\($0)", label: "Model \($0)") }
        for page in 1...100 {
            let cursor = page < 100 || hasNextPage ? "cursor-\(page)" : nil
            let step = state.receive(try response(requestID: page + 1, model: expected[page - 1], cursor: cursor))
            if page < 100 {
                try expectNextPage(step, requestID: page + 2, cursor: "cursor-\(page)")
            } else if hasNextPage {
                guard case .failed(let message) = step else {
                    Issue.record("Page 100 must fail without returning partial models or requesting page 101.")
                    return
                }
                #expect(message.contains("100-page limit"))
            } else {
                guard case .complete(let models) = step else {
                    Issue.record("The 100th final page must return the complete model list.")
                    return
                }
                #expect(models == expected)
            }
        }
    }

    @Test("A repeated Codex cursor fails without returning accumulated models or sending another request")
    func repeatedCursor() throws {
        var state = try initializedCodex()
        let first = AgentModel(id: "first", label: "First")
        try expectNextPage(
            state.receive(try response(requestID: 2, model: first, cursor: "same")), requestID: 3, cursor: "same"
        )
        let second = AgentModel(id: "second", label: "Second")
        let step = state.receive(try response(requestID: 3, model: second, cursor: "same"))
        guard case .failed(let message) = step else {
            Issue.record("Repeated cursors must fail without returning partial models or requesting another page.")
            return
        }
        #expect(message.contains("repeated"))
    }

    private func initializedCodex() throws -> ModelDiscoveryProtocol {
        var state = ModelDiscoveryProtocol(vendor: .codex)
        let step = state.receive(#"{"id":1,"result":{}}"#)
        try expectNextPage(step, requestID: 2, cursor: nil)
        return state
    }

    private func response(requestID: Int, model: AgentModel, cursor: String?) throws -> String {
        let result: [String: Any] = [
            "data": [["id": "opaque-\(model.id)", "model": model.id, "displayName": model.label]],
            "nextCursor": cursor as Any? ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: ["id": requestID, "result": result])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func expectNextPage(_ step: ModelDiscoveryProtocol.Step, requestID: Int, cursor: String?) throws {
        let output: String?
        if case .send(let request) = step { output = request } else { output = nil }
        let lines = try #require(output).split(whereSeparator: \.isNewline)
        let data = Data(try #require(lines.last).utf8)
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["id"] as? Int == requestID)
        #expect(request["method"] as? String == "model/list")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["limit"] as? Int == 100)
        #expect(params["includeHidden"] as? Bool == false)
        if let cursor {
            #expect(params["cursor"] as? String == cursor)
        } else {
            #expect(params["cursor"] is NSNull)
        }
    }
}
