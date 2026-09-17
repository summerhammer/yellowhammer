import CLIAdapters
import Testing

@Suite("CLIAdapterRegistry")
struct CLIAdapterRegistryTests {
    @Test("claude resolves to the ClaudeCodeAdapter")
    func claudeResolves() {
        let adapter = CLIAdapterRegistry.adapter(named: "claude")
        #expect(adapter?.cli == "claude")
        #expect(adapter is ClaudeCodeAdapter)
    }

    @Test("codex resolves to the CodexAdapter")
    func codexResolves() {
        let adapter = CLIAdapterRegistry.adapter(named: "codex")
        #expect(adapter?.cli == "codex")
        #expect(adapter is CodexAdapter)
    }

    @Test("allNames lists all registered adapter names")
    func allNamesListsRegisteredAdapters() {
        #expect(CLIAdapterRegistry.allNames == ["claude", "codex"])
    }

    @Test("An unknown name resolves to nil")
    func unknownNameResolvesToNil() {
        #expect(CLIAdapterRegistry.adapter(named: "gemini") == nil)
    }
}
