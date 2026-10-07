import Config
import Testing

@Suite("Agent CLI model discovery")
struct AgentModelDiscoveryTests {
    @Test("Claude Code SDK initialize choices keep their identifier separate from their display label")
    func claudeInitializationFixture() throws {
        let fixture = #"{"type":"control_response","response":{"request_id":"models","subtype":"success","#
            + #""response":{"models":[{"value":"default","displayName":"Default"},"#
            + #"{"value":"claude-fable-5-1[1m]","displayName":"Claude Fable 5.1 (1M context)"}]}}}"#
        let models = try #require(AgentModelDiscovery.parseClaudeInitializeResponse(fixture))
        #expect(models == [
            AgentModel(id: "default", label: "Default"),
            AgentModel(id: "claude-fable-5-1[1m]", label: "Claude Fable 5.1 (1M context)")
        ])
    }

    @Test("Codex model/list saves the model field rather than its opaque response id")
    func codexModelListFixture() throws {
        let fixture = #"{"id":"model-list","result":{"data":[{"id":"opaque-catalog-id","model":"gpt-5-codex","#
            + #""displayName":"GPT-5 Codex","hidden":false},{"id":"hidden-id","model":"secret","#
            + #""displayName":"Secret","hidden":true}]}}"#
        let models = try #require(AgentModelDiscovery.parseCodexResponse(fixture))
        #expect(models == [AgentModel(id: "gpt-5-codex", label: "GPT-5 Codex")])
    }

    @Test("Antigravity models maps tab-separated slugs to labels")
    func antigravityModelsFixture() {
        let models = AgentModelDiscovery.parseAntigravityModels(
            "claude-sonnet\tClaude Sonnet\ngemini-3-pro\tGemini 3 Pro\n"
        )
        #expect(models == [
            AgentModel(id: "claude-sonnet", label: "Claude Sonnet"),
            AgentModel(id: "gemini-3-pro", label: "Gemini 3 Pro")
        ])
    }

    @Test("Empty vendor lists remain empty and malformed responses remain failures")
    func emptyAndMalformed() throws {
        let emptyCodex = #"{"id":"model-list","result":{"data":[]}}"#
        #expect(try #require(AgentModelDiscovery.parseCodexResponse(emptyCodex)).isEmpty)
        #expect(AgentModelDiscovery.parseCodexResponse("not json") == nil)
        #expect(AgentModelDiscovery.parseClaudeInitializeResponse("{}") == nil)
        #expect(AgentModelDiscovery.parseAntigravityModels("\n") == [])
        #expect(AgentModelDiscovery.parseAntigravityModels("Please sign in") == nil)
    }
}
