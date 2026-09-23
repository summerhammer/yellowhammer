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

@Test("The default file is ~/.config/yellowhammer/config.toml")
func defaultFileURL() {
    let home = URL(filePath: "/Users/operator", directoryHint: .isDirectory)
    let url = MachineConfiguration.defaultFileURL(homeDirectory: home)
    #expect(url.path(percentEncoded: false) == "/Users/operator/.config/yellowhammer/config.toml")
}

@Test("A minimal file declares no CLI Adapters and an empty Routing Table")
func minimalFileLoads() throws {
    let configuration = try MachineConfiguration.load(contentsOf: fixture("minimal", in: "Valid"))
    #expect(configuration == MachineConfiguration(
        linearClientID: "yellowhammer-client-id",
        linearCredential: try credential("keychain:linear"),
        gitHubCredential: try credential("keychain:github"),
        cliAdapters: [],
        routingTable: []
    ))
}

@Test("A full file loads every CLI Adapter and Routing Entry, applying the route defaults")
func fullFileLoads() throws {
    let configuration = try MachineConfiguration.load(contentsOf: fixture("full", in: "Valid"))
    let expected = MachineConfiguration(
        linearClientID: "yellowhammer-client-id",
        linearCredential: try credential("keychain:linear"),
        gitHubCredential: try credential("keychain:github"),
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
        ],
        operatorIdentity: BoardObjectID(rawValue: "linear-user-1")
    )
    #expect(configuration == expected)
}

@Test("Tables may be written as dotted keys or inline tables")
func alternativeTableSpellings() throws {
    let text = """
    linear.credential = "keychain:linear"
    linear.client_id = "yellowhammer-client-id"
    github = { credential = "keychain:github" }
    cli.claude = {}
    routing = [{ route = "claude/opus/high" }]
    """
    let configuration = try MachineConfiguration.parse(text, file: "config.toml")
    #expect(configuration.linearClientID == "yellowhammer-client-id")
    #expect(configuration.operatorIdentity == nil)
    #expect(configuration.linearCredential == (try credential("keychain:linear")))
    #expect(configuration.gitHubCredential == (try credential("keychain:github")))
    #expect(configuration.routingTable == [RoutingEntry(route: try route("claude", "opus", "high"))])
}

@Test("[linear].operator must be a string when present")
func linearOperatorTypeMismatch() {
    let text = """
    [linear]
    credential = "keychain:linear"
    client_id = "yellowhammer-client-id"
    operator = 42
    [github]
    credential = "keychain:github"
    """
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected a non-string operator to fail")
    } catch {
        #expect(error.key == "linear.operator")
        #expect(error.reason == .typeMismatch(expected: "string", found: "integer"))
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

@Test("[linear] requires a non-empty string client_id", arguments: [
    ("credential = \"keychain:linear\"", 1, ConfigurationError.Reason.missingKey),
    ("credential = \"keychain:linear\"\nclient_id = \"\"", 3, .emptyString),
    ("credential = \"keychain:linear\"\nclient_id = 42", 3, .typeMismatch(expected: "string", found: "integer"))
])
func linearClientIDIsRequired(body: String, line: Int, reason: ConfigurationError.Reason) {
    let text = "[linear]\n\(body)\n\n[github]\ncredential = \"keychain:github\"\n"
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected the parse to fail")
    } catch {
        #expect(error.file == "config.toml")
        #expect(error.line == line, "\(error)")
        #expect(error.key == "linear.client_id", "\(error)")
        #expect(error.reason == reason, "\(error)")
    }
}

@Test("[linear].operator is the Operator identity's Linear user id, present, absent or empty")
func linearOperatorIdentity() throws {
    let present = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"
        operator = "user-123"

        [github]
        credential = "keychain:github"
        """
    let configured = try MachineConfiguration.parse(present, file: "config.toml")
    #expect(configured.operatorIdentity == BoardObjectID(rawValue: "user-123"))

    let absent = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"

        [github]
        credential = "keychain:github"
        """
    let unconfigured = try MachineConfiguration.parse(absent, file: "config.toml")
    #expect(unconfigured.operatorIdentity == nil)

    let empty = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"
        operator = ""

        [github]
        credential = "keychain:github"
        """
    let emptyConfigured = try MachineConfiguration.parse(empty, file: "config.toml")
    #expect(emptyConfigured.operatorIdentity == nil)
}

@Test("[github] still refuses a client_id key")
func gitHubRefusesClientID() {
    let text = """
    [linear]
    credential = "keychain:linear"
    client_id = "yellowhammer-client-id"

    [github]
    credential = "keychain:github"
    client_id = "yellowhammer-client-id"
    """
    do {
        _ = try MachineConfiguration.parse(text, file: "config.toml")
        Issue.record("expected the parse to fail")
    } catch {
        #expect(error.line == 7, "\(error)")
        #expect(error.key == "github.client_id", "\(error)")
        #expect(error.reason == .unknownKey, "\(error)")
    }
}
