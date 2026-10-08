import Config
import Testing

@Suite("MachineConfiguration.removingCodeHostingConnection")
struct RemovingCodeHostingConnectionTests {
    @Test("quoted header with spacing and inline comment is removed, preserving the next table's comment")
    func quotedCommentedHeader() {
        let text = """
        [code_hosting.github.connections. "alpha" ] # the connection
        type = "keychain"
        credential = "keychain:alpha"

        # belongs to beta
        [code_hosting.github.connections.beta]
        type = "gh"
        """

        let updated = MachineConfiguration.removingCodeHostingConnection(named: "alpha", inFileText: text)
        #expect(!updated.contains("connections. "))
        #expect(updated.contains("# belongs to beta\n[code_hosting.github.connections.beta]"))
        #expect(updated.contains("type = \"gh\""))
    }

    @Test("leaves text unchanged when no matching table exists")
    func missing() {
        let text = "[code_hosting.github.connections.beta]\ntype = \"gh\"\n"
        #expect(MachineConfiguration.removingCodeHostingConnection(named: "alpha", inFileText: text) == text)
    }
}
