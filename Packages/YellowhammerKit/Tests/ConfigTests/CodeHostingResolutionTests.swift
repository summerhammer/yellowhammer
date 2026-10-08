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
            CodeHostingConnection(name: "gh", kind: .githubCLI)
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
        #expect(resolved == CodeHostingCredential(connection: "acme", reference: reference))
    }

    @Test("A gh CLI connection is refused as not supported yet, naming the connection")
    func githubCLIConnectionIsRefused() throws {
        #expect(throws: CodeHostingRefusal.githubCLINotSupported(connection: "gh")) {
            try machine().codeHostingCredential(for: project(selecting: "gh"))
        }
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
        #expect(try machine.codeHostingCredential(connectionNamed: "acme").reference.rawValue == "keychain:github-acme")
        #expect(throws: CodeHostingRefusal.githubCLINotSupported(connection: "gh")) {
            try machine.codeHostingCredential(connectionNamed: "gh")
        }
        #expect(throws: CodeHostingRefusal.notInRegistry(connection: "nope")) {
            try machine.codeHostingCredential(connectionNamed: "nope")
        }
    }

    @Test("Refusals read as Operator-facing sentences that name the connection and never a secret")
    func refusalsDescribeThemselves() {
        let missing = CodeHostingRefusal.notInRegistry(connection: "acme").description
        #expect(missing.contains("\"acme\""))
        #expect(missing.contains("yh config connect-code-hosting acme --token-stdin"))
        let gh = CodeHostingRefusal.githubCLINotSupported(connection: "gh").description
        #expect(gh.contains("\"gh\""))
        #expect(gh.contains("gh CLI"))
    }
}
