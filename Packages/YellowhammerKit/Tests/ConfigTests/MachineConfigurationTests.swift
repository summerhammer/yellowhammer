import Config
import Domain
import Foundation
import Testing

private func fixture(_ name: String, in directory: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures/\(directory)"))
}

private func route(_ cli: String, _ model: String, _ effort: String) throws -> Route {
    try #require(Route(cli: cli, model: model, effort: effort))
}

private func kind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

private func credential(_ string: String) throws -> CredentialReference {
    try #require(CredentialReference(string))
}

private func keychainConnection(_ name: String, _ reference: String) throws -> CodeHostingConnection {
    CodeHostingConnection(name: name, kind: .keychainToken(try credential(reference)))
}

@Test("The default file is ~/.config/yellowhammer/config.toml")
func defaultFileURL() {
    let home = URL(filePath: "/Users/operator", directoryHint: .isDirectory)
    let url = MachineConfiguration.defaultFileURL(homeDirectory: home)
    #expect(url.path(percentEncoded: false) == "/Users/operator/.config/yellowhammer/config.toml")
}

@Test("A minimal file declares no Board Connections, no CLI Adapters and an empty Routing Table")
func minimalFileLoads() throws {
    let configuration = try MachineConfiguration.load(contentsOf: fixture("minimal", in: "Valid"))
    #expect(configuration == MachineConfiguration(
        linearInstallations: [],
        codeHostingConnections: [try keychainConnection("github", "keychain:github")],
        cliAdapters: [],
        routingTable: []
    ))
}

@Test("A full file loads every CLI Adapter and Routing Entry, applying the route defaults")
func fullFileLoads() throws {
    let configuration = try MachineConfiguration.load(contentsOf: fixture("full", in: "Valid"))
    let expected = MachineConfiguration(
        linearInstallations: [
            LinearInstallation(
                name: "acme",
                credential: try credential("keychain:linear-acme"),
                workspace: BoardObjectID(rawValue: "workspace-1"),
                appUser: BoardObjectID(rawValue: "app-user-1"),
                operatorIdentity: BoardObjectID(rawValue: "linear-user-1")
            ),
            LinearInstallation(
                name: "acme corp",
                credential: try credential("keychain:linear-acme-corp"),
                workspace: BoardObjectID(rawValue: "workspace-2"),
                appUser: BoardObjectID(rawValue: "app-user-2")
            )
        ],
        codeHostingConnections: [try keychainConnection("github", "keychain:github")],
        cliAdapters: [
            CLIAdapterDeclaration(name: "claude", executable: "/opt/homebrew/bin/claude"),
            CLIAdapterDeclaration(name: "codex"),
            CLIAdapterDeclaration(name: "local agent", executable: "/usr/local/bin/agent")
        ],
        routingTable: [
            RoutingEntry(route: try route("claude", "sonnet", "medium")),
            RoutingEntry(
                kind: try kind("impl.boilerplate"),
                repoRole: .role(.backend),
                route: try route("claude", "sonnet", "low"),
                fallbacks: [
                    try route("codex", "gpt-5.4", "high"),
                    try route("claude", "haiku", "low"),
                    try route("claude", "opus", "high"),
                    try route("codex", "gpt-5.4", "low")
                ]
            ),
            RoutingEntry(
                repoRole: .role(.mobile),
                route: try route("codex", "gpt-5.4", "medium"),
                fallbacks: [try route("claude", "opus", "medium")]
            ),
            RoutingEntry(kind: try kind("review"), route: try route("claude", "opus", "high")),
            RoutingEntry(
                kind: try kind("impl"),
                repoRole: .role(RepoRole(rawValue: "data-pipeline")),
                route: try route("claude", "sonnet", "xhigh")
            )
        ]
    )
    #expect(configuration == expected)
}

@Test("Tables may be written as dotted keys or inline tables")
func alternativeTableSpellings() throws {
    let text = """
    board.linear.connections.acme = { credential = "keychain:linear", workspace = "w1", yellowhammer_identity = "u1" }
    code_hosting.github.connections.github = { type = "keychain", credential = "keychain:github" }
    code_hosting.github.connections.gh = { type = "gh" }
    cli.claude = {}
    routing = [{ route = "claude/opus/high" }]
    """
    let configuration = try MachineConfiguration.parse(text, file: "config.toml")
    #expect(configuration.linearInstallations.map(\.name) == ["acme"])
    #expect(configuration.linearInstallations.first?.operatorIdentity == nil)
    #expect(configuration.linearInstallations.first?.credential == (try credential("keychain:linear")))
    #expect(configuration.codeHostingConnections == [
        CodeHostingConnection(name: "github", kind: .keychainToken(try credential("keychain:github"))),
        CodeHostingConnection(name: "gh", kind: .githubCLI)
    ])
    #expect(configuration.routingTable == [RoutingEntry(route: try route("claude", "opus", "high"))])
}

@Test("Legacy installation table and app_user keys are rejected")
func legacyBoardConnectionKeysAreRejected() {
    let legacyTable = """
    [board.linear.installations.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    """ + githubSection
    let legacyIdentity = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "workspace-1"
    app_user = "app-user-1"
    """ + githubSection

    #expect(throws: (any Error).self) { try MachineConfiguration.parse(legacyTable, file: "config.toml") }
    #expect(throws: (any Error).self) { try MachineConfiguration.parse(legacyIdentity, file: "config.toml") }
}

private let githubSection = """

    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"
    """

@Test("A machine file with no [board] declares zero Board Connections")
func noBoardMeansNoInstallations() throws {
    let configuration = try MachineConfiguration.parse(githubSection, file: "config.toml")
    #expect(configuration.linearInstallations == [])
}

@Test("An empty [board.linear.connections], an empty [board.linear] and an empty [board] declare none")
func emptyRegistryMeansNoInstallations() throws {
    for header in ["[board.linear.connections]", "[board.linear]", "[board]"] {
        let configuration = try MachineConfiguration.parse(header + "\n" + githubSection, file: "config.toml")
        #expect(configuration.linearInstallations == [], "\(header)")
    }
}

@Test("Two installations decode in file order with every field; operator is optional or empty")
func installationsDecodeInFileOrder() throws {
    let text = """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        operator = "user-123"

        [board.linear.connections."acme corp"]
        credential = "keychain:linear-corp"
        workspace = "workspace-2"
        yellowhammer_identity = "app-user-2"
        operator = ""
        """ + githubSection
    let configuration = try MachineConfiguration.parse(text, file: "config.toml")
    #expect(configuration.linearInstallations == [
        LinearInstallation(
            name: "acme",
            credential: try credential("keychain:linear-acme"),
            workspace: BoardObjectID(rawValue: "workspace-1"),
            appUser: BoardObjectID(rawValue: "app-user-1"),
            operatorIdentity: BoardObjectID(rawValue: "user-123")
        ),
        LinearInstallation(
            name: "acme corp",
            credential: try credential("keychain:linear-corp"),
            workspace: BoardObjectID(rawValue: "workspace-2"),
            appUser: BoardObjectID(rawValue: "app-user-2"),
            operatorIdentity: nil
        )
    ])
    #expect(configuration.linearInstallation(named: "acme corp")?.workspace == BoardObjectID(rawValue: "workspace-2"))
    #expect(configuration.linearInstallation(named: "nope") == nil)
}

@Test("A missing operator key decodes to nil")
func absentOperatorIsNil() throws {
    let text = """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        """ + githubSection
    let configuration = try MachineConfiguration.parse(text, file: "config.toml")
    #expect(configuration.linearInstallations.first?.operatorIdentity == nil)
}

@Test("linearInstallation(for:) returns the Project's own entry among several")
func installationForProject() throws {
    func installation(_ name: String) throws -> LinearInstallation {
        LinearInstallation(
            name: name, credential: try credential("keychain:\(name)"),
            workspace: BoardObjectID(rawValue: "ws-\(name)"), appUser: BoardObjectID(rawValue: "au-\(name)")
        )
    }
    let machine = MachineConfiguration(
        linearInstallations: [try installation("a"), try installation("b")],
        cliAdapters: [], routingTable: []
    )
    func project(_ installationName: String) throws -> ProjectConfiguration {
        ProjectConfiguration(
            id: try #require(ProjectID(rawValue: "p")), name: "P", linearInstallationName: installationName,
            linearProject: "P", codeHostingConnectionName: "github", specSource: "/spec", repos: []
        )
    }
    #expect(machine.linearInstallation(for: try project("b"))?.name == "b")
    #expect(machine.linearInstallation(for: try project("a"))?.name == "a")
    #expect(machine.linearInstallation(for: try project("c")) == nil)
}

@Test("An installation's operator must be a string when present")
func installationOperatorTypeMismatch() {
    let text = """
    [board.linear.connections.acme]
    credential = "keychain:linear"
    workspace = "w1"
    yellowhammer_identity = "u1"
    operator = 42
    """ + githubSection
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected a non-string operator to fail")
    } catch {
        #expect(error.key == "board.linear.connections.acme.operator")
        #expect(error.reason == .typeMismatch(expected: "string", found: "integer"))
    }
}

@Test("A quoted installation name renders quoted in the key of its errors")
func quotedInstallationNameInKey() {
    let text = """
    [board.linear.connections."acme corp"]
    credential = "keychain:linear"
    yellowhammer_identity = "u1"
    """ + githubSection
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected the parse to fail")
    } catch {
        #expect(error.key == "board.linear.connections.\"acme corp\".workspace", "\(error)")
        #expect(error.reason == .missingKey)
    }
}

@Test("An unreadable file is a ConfigurationError")
func unreadableFile() {
    let url = URL(filePath: "/nonexistent/yellowhammer/config.toml")
    do {
        _ = try MachineConfiguration.load(contentsOf: url)
        Issue.record("expected an error")
    } catch {
        #expect(error.file == "/nonexistent/yellowhammer/config.toml")
        #expect(error.line == 1)
        #expect(error.key == nil)
        guard case .unreadable = error.reason else {
            Issue.record("expected .unreadable, got \(error.reason)")
            return
        }
    }
}

@Test("The description names file, line and key")
func errorDescription() {
    let error = ConfigurationError(
        file: "config.toml", line: 12, key: "routing[1].route", reason: .invalidRoute("claude")
    )
    #expect(error.description == """
        config.toml:12: routing[1].route: expected "cli/model" or "cli/model/effort", got "claude"
        """)
    let keyless = ConfigurationError(file: "config.toml", line: 2, key: nil, reason: .syntax("expected a key"))
    #expect(keyless.description == "config.toml:2: expected a key")
}

@Test("The old machine-wide [github] table is refused as an unknown key")
func oldGitHubTableIsRefused() {
    let text = """
    [github]
    credential = "keychain:github"
    """
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected the parse to fail")
    } catch {
        #expect(error.line == 1, "\(error)")
        #expect(error.key == "github", "\(error)")
        #expect(error.reason == .unknownKey, "\(error)")
    }
}

@Test("An empty [code_hosting.github.connections], [code_hosting.github] and [code_hosting] declare none")
func emptyCodeHostingRegistryMeansNoConnections() throws {
    let headers = ["[code_hosting.github.connections]", "[code_hosting.github]", "[code_hosting]"]
    for header in headers + [""] {
        let configuration = try MachineConfiguration.parse(header, file: "config.toml")
        #expect(configuration.codeHostingConnections == [], "\(header)")
    }
}

@Test("Code Hosting Connections decode in file order; the lookups find them by name and by Project")
func codeHostingConnectionsDecodeInFileOrder() throws {
    let text = """
        [code_hosting.github.connections.acme]
        type = "keychain"
        credential = "keychain:github-acme"

        [code_hosting.github.connections."my gh"]
        type = "gh"
        """
    let configuration = try MachineConfiguration.parse(text, file: "config.toml")
    #expect(configuration.codeHostingConnections == [
        CodeHostingConnection(name: "acme", kind: .keychainToken(try credential("keychain:github-acme"))),
        CodeHostingConnection(name: "my gh", kind: .githubCLI)
    ])
    #expect(configuration.codeHostingConnection(named: "my gh")?.kind == .githubCLI)
    #expect(configuration.codeHostingConnection(named: "nope") == nil)

    func project(_ connection: String) throws -> ProjectConfiguration {
        ProjectConfiguration(
            id: try #require(ProjectID(rawValue: "p")), name: "P", linearInstallationName: "a",
            linearProject: "P", codeHostingConnectionName: connection, specSource: "/spec", repos: []
        )
    }
    #expect(configuration.codeHostingConnection(for: try project("acme"))?.name == "acme")
    #expect(configuration.codeHostingConnection(for: try project("c")) == nil)
}

@Test("The default connection name and its Credential Reference")
func codeHostingDefaults() {
    #expect(CodeHostingConnection.defaultName == "github")
    #expect(CodeHostingConnection.defaultCredentialReference(for: "github").rawValue == "keychain:github")
    #expect(CodeHostingConnection.defaultCredentialReference(for: "acme").rawValue == "keychain:acme")
}
