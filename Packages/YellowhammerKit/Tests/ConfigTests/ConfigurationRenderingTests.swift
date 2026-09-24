import Config
import Domain
import Testing

private func route(_ cli: String, _ model: String, _ effort: String = "medium") throws -> Route {
    try #require(Route(cli: cli, model: model, effort: effort))
}

private func kind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

private func credential(_ string: String) throws -> CredentialReference {
    try #require(CredentialReference(string))
}

private func projectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

// MARK: - Project round-trip

@Test("A Project with defaults round-trips through renderedTOML")
func projectDefaultsRoundTrip() throws {
    let project = ProjectConfiguration(
        id: try projectID("roundtrip"),
        name: "Round Trip",
        linearProject: "RT",
        specSource: "~/dev/roundtrip-spec",
        repos: [
            RepoDeclaration(name: "only-repo", path: "~/dev/roundtrip", role: .backend, check: .command("swift test"))
        ]
    )
    let parsed = try ProjectConfiguration.parse(project.renderedTOML, file: "roundtrip.toml")
    #expect(parsed == project)
}

@Test("A Project with repos, protected paths, a spec role, a GitHub override, routing overrides and a quoted check")
func projectFullRoundTrip() throws {
    let project = ProjectConfiguration(
        id: try projectID("full-roundtrip"),
        name: "Full Round Trip",
        linearProject: "FRT",
        repos: [
            RepoDeclaration(
                name: "backend",
                path: "~/dev/full-roundtrip-backend",
                role: .backend,
                check: .command(#"swift test --filter "Foo\Bar""#),
                protectedPaths: ["Secrets/", "Private/"]
            ),
            RepoDeclaration(
                name: "spec-repo",
                path: "~/dev/full-roundtrip-spec-repo",
                role: .spec,
                check: .none
            )
        ],
        bounds: Bounds(
            reviewRoundsMax: 3, attemptsPerCard: 5, unansweredNightsMax: 4,
            reselectionsMax: 3, consecutiveRefusalsMax: 5, failedAdoptionsMax: 3
        ),
        schedule: Schedule(
            nightStart: try #require(TimeOfDay(hour: 23, minute: 0)),
            nightEnd: try #require(TimeOfDay(hour: 7, minute: 0)),
            buildEveryMinutes: 20
        ),
        gitHubCredential: try credential("keychain:github-full"),
        routingOverrides: [
            RoutingEntry(
                kind: try kind("impl.boilerplate"),
                repoRole: .role(.backend),
                route: try route("claude", "sonnet", "low"),
                fallbacks: [try route("codex", "gpt-5.4", "high"), try route("claude", "haiku", "low")]
            ),
            RoutingEntry(kind: try kind("review"), route: try route("claude", "opus", "high"))
        ]
    )
    let parsed = try ProjectConfiguration.parse(project.renderedTOML, file: "full-roundtrip.toml")
    #expect(parsed == project)
}

@Test("A Project rendered from Bounds()/Schedule() contains the spec's unanswered_nights_max default")
func projectRendersExplicitDefaultBounds() throws {
    let project = ProjectConfiguration(
        id: try projectID("bounds-default"),
        name: "Bounds Default",
        linearProject: "BD",
        repos: [RepoDeclaration(name: "only-repo", path: "~/dev/bd", role: .backend, check: .none)]
    )
    #expect(project.renderedTOML.contains("unanswered_nights_max = 3"))
}

// MARK: - Machine file round-trip

@Test("A minimal machine file (no operator, no CLI adapters, no routing) round-trips")
func machineMinimalRoundTrip() throws {
    let machine = MachineConfiguration(
        linearClientID: "yellowhammer-client-id",
        linearCredential: try credential("keychain:linear"),
        gitHubCredential: try credential("keychain:github"),
        cliAdapters: [],
        routingTable: []
    )
    let parsed = try MachineConfiguration.parse(machine.renderedTOML, file: "config.toml")
    #expect(parsed == machine)
}

@Test("A full machine file with an operator, CLI tables with/without executable, and routing fallbacks")
func machineFullRoundTrip() throws {
    let machine = MachineConfiguration(
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
                fallbacks: [try route("codex", "gpt-5.4", "high"), try route("claude", "opus", "high")]
            )
        ],
        operatorIdentity: BoardObjectID(rawValue: "linear-user-1")
    )
    let parsed = try MachineConfiguration.parse(machine.renderedTOML, file: "config.toml")
    #expect(parsed == machine)
}

// MARK: - settingOperator

@Test("settingOperator inserts operator right after [linear] when absent")
func settingOperatorInsertsWhenAbsent() throws {
    let text = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"

        [github]
        credential = "keychain:github"
        """
    let result = MachineConfiguration.settingOperator(BoardObjectID(rawValue: "user-1"), inFileText: text)
    let parsed = try MachineConfiguration.parse(result, file: "config.toml")
    #expect(parsed.operatorIdentity == BoardObjectID(rawValue: "user-1"))
    #expect(result.contains(#"operator = "user-1""#))
}

@Test("settingOperator replaces an existing operator line, preserving comments and unrelated keys")
func settingOperatorReplacesWhenPresent() throws {
    let text = """
        # machine-wide configuration
        [linear]
        credential = "keychain:linear" # do not touch
        operator = "old-user"
        client_id = "yellowhammer-client-id"

        [github]
        credential = "keychain:github"
        """
    let result = MachineConfiguration.settingOperator(BoardObjectID(rawValue: "new-user"), inFileText: text)
    #expect(result.contains("# machine-wide configuration"))
    #expect(result.contains(#"credential = "keychain:linear" # do not touch"#))
    #expect(result.contains(#"operator = "new-user""#))
    #expect(!result.contains("old-user"))
    let parsed = try MachineConfiguration.parse(result, file: "config.toml")
    #expect(parsed.operatorIdentity == BoardObjectID(rawValue: "new-user"))
}

@Test("settingOperator is idempotent")
func settingOperatorIsIdempotent() {
    let text = """
        [linear]
        credential = "keychain:linear"
        client_id = "yellowhammer-client-id"

        [github]
        credential = "keychain:github"
        """
    let once = MachineConfiguration.settingOperator(BoardObjectID(rawValue: "user-1"), inFileText: text)
    let twice = MachineConfiguration.settingOperator(BoardObjectID(rawValue: "user-1"), inFileText: once)
    #expect(once == twice)
}
