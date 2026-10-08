import Config
import Domain
import Testing

@Suite("MachineConfiguration.settingCodeHostingConnection")
struct CodeHostingRegistryEditingTests {
    private func keychain(_ name: String, _ reference: String) throws -> CodeHostingConnection {
        CodeHostingConnection(name: name, kind: .keychainToken(try #require(CredentialReference(reference))))
    }

    private let withBoard = """
        # machine file
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "ws"
        yellowhammer_identity = "app"

        [cli.claude]

        """

    @Test("On an empty file it creates the table")
    func emptyFile() throws {
        let entry = try keychain("github", "keychain:github")
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: "")
        #expect(result == """
            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"

            """)
        #expect(try MachineConfiguration.parse(result, file: "config.toml").codeHostingConnections == [entry])
    }

    @Test("Beside Board Connections it appends the table and keeps every other line")
    func besideBoardConnections() throws {
        let entry = try keychain("acme gh", "keychain:github-acme")
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: withBoard)
        #expect(result.hasPrefix(withBoard))
        #expect(result.contains("[code_hosting.github.connections.\"acme gh\"]"))
        let parsed = try MachineConfiguration.parse(result, file: "config.toml")
        #expect(parsed.codeHostingConnections == [entry])
        #expect(parsed.linearInstallations.map(\.name) == ["acme"])
        #expect(parsed.cliAdapters.map(\.name) == ["claude"])
    }

    @Test("Applying it twice equals applying it once")
    func idempotent() throws {
        let entries = [
            try keychain("github", "keychain:github"),
            CodeHostingConnection(name: "gh", kind: .githubCLI(executable: nil)),
            CodeHostingConnection(name: "gh2", kind: .githubCLI(executable: "/opt/homebrew/bin/gh"))
        ]
        for entry in entries {
            let once = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: withBoard)
            #expect(MachineConfiguration.settingCodeHostingConnection(entry, inFileText: once) == once)
        }
    }

    @Test("An existing entry is set in place, keeping comments and its siblings")
    func replacesInPlace() throws {
        let text = """
            [code_hosting.github.connections.github]
            # keep me
            type = "keychain"
            credential = "keychain:old"

            [code_hosting.github.connections.other]
            type = "keychain"
            credential = "keychain:other"
            """
        let entry = try keychain("github", "keychain:new")
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: text)
        #expect(result.contains("# keep me"))
        let parsed = try MachineConfiguration.parse(result, file: "config.toml")
        #expect(parsed.codeHostingConnection(named: "github") == entry)
        #expect(parsed.codeHostingConnection(named: "other") == (try keychain("other", "keychain:other")))
    }

    @Test("Turning a Keychain entry into a gh entry drops its credential")
    func keychainToGitHubCLI() throws {
        let text = "[code_hosting.github.connections.work]\ntype = \"keychain\"\ncredential = \"keychain:work\"\n"
        let entry = CodeHostingConnection(name: "work", kind: .githubCLI(executable: nil))
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: text)
        #expect(!result.contains("credential"))
        #expect(try MachineConfiguration.parse(result, file: "config.toml").codeHostingConnections == [entry])
    }

    @Test("A Keychain entry missing its credential line gets one")
    func insertsMissingCredential() throws {
        let text = "[code_hosting.github.connections.work]\ntype = \"keychain\"\n"
        let entry = try keychain("work", "keychain:work")
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: text)
        #expect(try MachineConfiguration.parse(result, file: "config.toml").codeHostingConnections == [entry])
    }

    @Test("A gh entry's executable is set, replaced and removed in place")
    func githubCLIExecutableEditing() throws {
        let text = "[code_hosting.github.connections.work]\ntype = \"gh\"\n"
        let declared = CodeHostingConnection(name: "work", kind: .githubCLI(executable: "/opt/homebrew/bin/gh"))
        let withPath = MachineConfiguration.settingCodeHostingConnection(declared, inFileText: text)
        #expect(try MachineConfiguration.parse(withPath, file: "config.toml").codeHostingConnections == [declared])

        let undeclared = CodeHostingConnection(name: "work", kind: .githubCLI(executable: nil))
        let without = MachineConfiguration.settingCodeHostingConnection(undeclared, inFileText: withPath)
        #expect(!without.contains("executable"))
        #expect(try MachineConfiguration.parse(without, file: "config.toml").codeHostingConnections == [undeclared])
    }

    @Test("Turning a gh entry with an executable into a Keychain entry drops the executable")
    func githubCLIToKeychain() throws {
        let text = "[code_hosting.github.connections.work]\ntype = \"gh\"\nexecutable = \"/opt/gh\"\n"
        let entry = try keychain("work", "keychain:work")
        let result = MachineConfiguration.settingCodeHostingConnection(entry, inFileText: text)
        #expect(!result.contains("executable"))
        #expect(try MachineConfiguration.parse(result, file: "config.toml").codeHostingConnections == [entry])
    }
}
