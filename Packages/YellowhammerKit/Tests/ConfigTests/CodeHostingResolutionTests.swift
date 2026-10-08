import Config
import Domain
import Testing

private func credential(_ string: String) throws -> CredentialReference {
    try #require(CredentialReference(string))
}

private func machine() throws -> MachineConfiguration {
    MachineConfiguration(
        codeHostingConnections: [
            CodeHostingConnection(name: "acme", kind: .keychainToken(try credential("keychain:github-acme"))),
            CodeHostingConnection(name: "gh", kind: .githubCLI(executable: nil))
        ],
        cliAdapters: [],
        routingTable: []
    )
}

private func project(selecting connection: String) throws -> ProjectConfiguration {
    ProjectConfiguration(
        id: try #require(ProjectID(rawValue: "alpha")), name: "Alpha", linearInstallationName: "acme",
        linearProject: "ALP", codeHostingConnectionName: connection, specSource: "~/spec", repos: []
    )
}

@Suite("MachineConfiguration.codeHostingCredential")
struct CodeHostingResolutionTests {
    @Test("A Project selecting a Keychain token connection resolves to its Credential Reference")
    func keychainConnectionResolves() throws {
        let resolved = try machine().codeHostingCredential(for: project(selecting: "acme"))
        let reference = try credential("keychain:github-acme")
        #expect(resolved == .keychainToken(connection: "acme", reference: reference))
        #expect(resolved.connection == "acme")
    }

    @Test("A gh CLI connection resolves to the gh credential, with no Credential Reference")
    func githubCLIConnectionResolves() throws {
        let resolved = try machine().codeHostingCredential(for: project(selecting: "gh"))
        #expect(resolved == .githubCLI(connection: "gh", executable: nil))
        #expect(resolved.connection == "gh")
    }

    @Test("A gh CLI connection's declared executable is carried through")
    func githubCLIDeclaredExecutable() throws {
        let machine = MachineConfiguration(
            codeHostingConnections: [CodeHostingConnection(name: "gh", kind: .githubCLI(executable: "/opt/gh/bin/gh"))],
            cliAdapters: [], routingTable: []
        )
        #expect(try machine.codeHostingCredential(connectionNamed: "gh")
            == .githubCLI(connection: "gh", executable: "/opt/gh/bin/gh"))
    }

    @Test("A selection absent from the registry is refused as not in the registry")
    func unknownConnectionIsRefused() throws {
        #expect(throws: CodeHostingRefusal.notInRegistry(connection: "missing")) {
            try machine().codeHostingCredential(for: project(selecting: "missing"))
        }
    }

    @Test("The by-name variant resolves the same way")
    func byNameVariant() throws {
        let machine = try machine()
        #expect(try machine.codeHostingCredential(connectionNamed: "acme")
            == .keychainToken(connection: "acme", reference: credential("keychain:github-acme")))
        #expect(try machine.codeHostingCredential(connectionNamed: "gh")
            == .githubCLI(connection: "gh", executable: nil))
        #expect(throws: CodeHostingRefusal.notInRegistry(connection: "nope")) {
            try machine.codeHostingCredential(connectionNamed: "nope")
        }
    }

    @Test("Refusals read as Operator-facing sentences that name the connection and never a secret")
    func refusalsDescribeThemselves() {
        let missing = CodeHostingRefusal.notInRegistry(connection: "acme").description
        #expect(missing.contains("\"acme\""))
        #expect(missing.contains("yh config connect-code-hosting acme --token-stdin"))
    }
}
