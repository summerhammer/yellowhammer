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
        linearInstallationName: "acme",
        linearProject: "RT",
        codeHostingConnectionName: "github",
        specSource: "~/dev/roundtrip-spec",
        repos: [
            RepoDeclaration(name: "only-repo", path: "~/dev/roundtrip", role: .backend, check: .command("swift test"))
        ]
    )
    let parsed = try ProjectConfiguration.parse(project.renderedTOML, file: "roundtrip.toml")
    #expect(parsed == project)
}

@Test("A Project with repos, a spec role, a Code Hosting selection, a PR title, routing overrides and a quoted check")
func projectFullRoundTrip() throws {
    let project = ProjectConfiguration(
        id: try projectID("full-roundtrip"),
        name: "Full Round Trip",
        linearInstallationName: "acme",
        linearProject: "FRT",
        codeHostingConnectionName: "github-full",
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
            reviewRoundsMax: 3, attemptsPerWorkCard: 5, unansweredNightsMax: 4,
            reselectionsMax: 3, consecutiveRefusalsMax: 5, failedAdoptionsMax: 3
        ),
        schedule: Schedule(
            nightStart: try #require(TimeOfDay(hour: 23, minute: 0)),
            nightEnd: try #require(TimeOfDay(hour: 7, minute: 0)),
            buildEveryMinutes: 20
        ),
        routingOverrides: [
            RoutingEntry(
                kind: try kind("impl.boilerplate"),
                repoRole: .role(.backend),
                route: try route("claude", "sonnet", "low"),
                fallbacks: [try route("codex", "gpt-5.4", "high"), try route("claude", "haiku", "low")]
            ),
            RoutingEntry(kind: try kind("review"), route: try route("claude", "opus", "high"))
        ],
        pullRequestTitle: try MessageTemplate("[{key}] {title}", kind: .pullRequestTitle)
    )
    let parsed = try ProjectConfiguration.parse(project.renderedTOML, file: "full-roundtrip.toml")
    #expect(parsed == project)
}

@Test("A Project rendered from Bounds()/Schedule() contains the spec's overdue_nights_max default")
func projectRendersExplicitDefaultBounds() throws {
    let project = ProjectConfiguration(
        id: try projectID("bounds-default"),
        name: "Bounds Default",
        linearInstallationName: "acme",
        linearProject: "BD",
        codeHostingConnectionName: "github",
        repos: [RepoDeclaration(name: "only-repo", path: "~/dev/bd", role: .backend, check: .none)]
    )
    #expect(project.renderedTOML.contains("overdue_nights_max = 3"))
}

// MARK: - Machine file round-trip

@Test("A minimal machine file (no Board Connections, no CLI adapters, no routing) round-trips")
func machineMinimalRoundTrip() throws {
    let machine = MachineConfiguration(cliAdapters: [], routingTable: [])
    let parsed = try MachineConfiguration.parse(machine.renderedTOML, file: "config.toml")
    #expect(parsed == machine)
}

@Test("A full machine file with Board and Code Hosting Connections, CLI tables and routing fallbacks")
func machineFullRoundTrip() throws {
    let machine = MachineConfiguration(
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
                credential: try credential("keychain:linear-corp"),
                workspace: BoardObjectID(rawValue: "workspace-2"),
                appUser: BoardObjectID(rawValue: "app-user-2")
            )
        ],
        codeHostingConnections: [
            CodeHostingConnection(name: "github", kind: .keychainToken(try credential("keychain:github"))),
            CodeHostingConnection(name: "work gh", kind: .githubCLI(executable: nil)),
            CodeHostingConnection(name: "acme", kind: .keychainToken(try credential("keychain:github-acme")))
        ],
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
        ]
    )
    let parsed = try MachineConfiguration.parse(machine.renderedTOML, file: "config.toml")
    #expect(parsed == machine)
}

// MARK: - settingOperator

private let registryText = """
    # Machine file.
    [board.linear.connections.acme]
    credential = "keychain:linear-acme"
    workspace = "workspace-1"
    yellowhammer_identity = "app-user-1"
    operator = "old-user"

    [board.linear.connections."acme corp"]
    credential = "keychain:linear-corp"
    workspace = "workspace-2"
    yellowhammer_identity = "app-user-2"
    operator = "corp-user"

    [code_hosting.github.connections.github]
    type = "keychain"
    credential = "keychain:github"
    """

private func operatorOf(_ text: String, _ name: String) throws -> BoardObjectID? {
    try MachineConfiguration.parse(text, file: "config.toml").linearInstallation(named: name)?.operatorIdentity
}

@Test("settingOperator replaces the operator in the named entry only, leaving its sibling alone")
func settingOperatorReplacesInNamedEntry() throws {
    let result = MachineConfiguration.settingOperator(
        BoardObjectID(rawValue: "new-user"), installation: "acme", inFileText: registryText
    )
    #expect(try operatorOf(result, "acme") == BoardObjectID(rawValue: "new-user"))
    #expect(try operatorOf(result, "acme corp") == BoardObjectID(rawValue: "corp-user"))
    #expect(result.contains("# Machine file."))
}

@Test("settingOperator works with a quoted name and leaves the other entry alone")
func settingOperatorQuotedName() throws {
    let result = MachineConfiguration.settingOperator(
        BoardObjectID(rawValue: "new-corp"), installation: "acme corp", inFileText: registryText
    )
    #expect(try operatorOf(result, "acme corp") == BoardObjectID(rawValue: "new-corp"))
    #expect(try operatorOf(result, "acme") == BoardObjectID(rawValue: "old-user"))
}

@Test("settingOperator inserts operator after the table's last key when absent")
func settingOperatorInserts() throws {
    let text = """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"
        """
    let result = MachineConfiguration.settingOperator(
        BoardObjectID(rawValue: "user-1"), installation: "acme", inFileText: text
    )
    #expect(try operatorOf(result, "acme") == BoardObjectID(rawValue: "user-1"))
    #expect(result.contains(
        "yellowhammer_identity = \"app-user-1\"\noperator = \"user-1\"\n\n[code_hosting.github.connections.github]"
    ))
}

@Test("settingOperator matches a quoted-but-bare-safe header and a header with a trailing comment")
func settingOperatorHeaderSpellings() throws {
    for header in [
        "[board.linear.connections.\"acme\"]",
        "[ board . linear . connections . acme ]  # the main one",
        "[board.linear.connections.acme] # note"
    ] {
        let text = header + "\ncredential = \"c\"\nworkspace = \"w\"\nyellowhammer_identity = \"a\"\n"
            + "\n[code_hosting.github.connections.github]\ntype = \"keychain\"\ncredential = \"g\"\n"
        let result = MachineConfiguration.settingOperator(
            BoardObjectID(rawValue: "u"), installation: "acme", inFileText: text
        )
        #expect(try operatorOf(result, "acme") == BoardObjectID(rawValue: "u"), "\(header)")
    }
}

@Test("settingOperator leaves the text unchanged when the entry is absent, and is idempotent")
func settingOperatorAbsentAndIdempotent() {
    let user = BoardObjectID(rawValue: "user-1")
    #expect(MachineConfiguration.settingOperator(user, installation: "nope", inFileText: registryText) == registryText)
    let once = MachineConfiguration.settingOperator(user, installation: "acme", inFileText: registryText)
    #expect(MachineConfiguration.settingOperator(user, installation: "acme", inFileText: once) == once)
}

// MARK: - settingLinearInstallation

private func installation(
    _ name: String, workspace: String = "ws", operatorIdentity: String? = nil
) throws -> LinearInstallation {
    LinearInstallation(
        name: name, credential: try credential("keychain:linear-\(name)"),
        workspace: BoardObjectID(rawValue: workspace), appUser: BoardObjectID(rawValue: "au-\(name)"),
        operatorIdentity: operatorIdentity.map { BoardObjectID(rawValue: $0) }
    )
}

@Test("settingLinearInstallation appends a new entry after [[routing]] and the result parses")
func settingInstallationAppends() throws {
    let text = """
        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"

        [cli.claude]

        [[routing]]
        route = "claude/sonnet"
        """
    let entry = try installation("acme", operatorIdentity: "u1")
    let result = MachineConfiguration.settingLinearInstallation(entry, inFileText: text)
    #expect(result.hasSuffix("operator = \"u1\"\n"))
    let parsed = try MachineConfiguration.parse(result, file: "config.toml")
    #expect(parsed.linearInstallations == [entry])
    #expect(parsed.routingTable == [RoutingEntry(route: try route("claude", "sonnet"))])
    #expect(parsed.cliAdapters.map(\.name) == ["claude"])
    #expect(MachineConfiguration.settingLinearInstallation(entry, inFileText: result) == result)
}

@Test("settingLinearInstallation replaces an existing entry's fields, keeping its operator and comments")
func settingInstallationReplaces() throws {
    let text = """
        [board.linear.connections.acme]
        # keep me
        credential = "keychain:old"
        workspace = "old-ws"
        operator = "kept-user"

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"
        """
    let entry = try installation("acme", workspace: "new-ws")
    let result = MachineConfiguration.settingLinearInstallation(entry, inFileText: text)
    #expect(result.contains("# keep me"))
    let parsed = try #require(
        MachineConfiguration.parse(result, file: "config.toml").linearInstallation(named: "acme")
    )
    #expect(parsed.credential == entry.credential)
    #expect(parsed.workspace == BoardObjectID(rawValue: "new-ws"))
    #expect(parsed.appUser == entry.appUser)
    #expect(parsed.operatorIdentity == BoardObjectID(rawValue: "kept-user"))
    #expect(MachineConfiguration.settingLinearInstallation(entry, inFileText: result) == result)
}

@Test("settingLinearInstallation writes a non-nil operator over an existing one")
func settingInstallationReplacesOperator() throws {
    let entry = try installation("acme", operatorIdentity: "fresh")
    let result = MachineConfiguration.settingLinearInstallation(entry, inFileText: registryText)
    #expect(try operatorOf(result, "acme") == BoardObjectID(rawValue: "fresh"))
    #expect(try operatorOf(result, "acme corp") == BoardObjectID(rawValue: "corp-user"))
}

@Test("settingLinearInstallation adds a second entry beside an existing one, and quotes a name that needs it")
func settingInstallationSecondAndQuoted() throws {
    let first = try installation("acme", workspace: "ws-1")
    let hosting = "[code_hosting.github.connections.github]\ntype = \"keychain\"\ncredential = \"keychain:github\"\n"
    let withFirst = MachineConfiguration.settingLinearInstallation(first, inFileText: hosting)
    let second = try installation("acme corp", workspace: "ws-2")
    let result = MachineConfiguration.settingLinearInstallation(second, inFileText: withFirst)
    #expect(result.contains("[board.linear.connections.\"acme corp\"]"))
    let parsed = try MachineConfiguration.parse(result, file: "config.toml")
    #expect(parsed.linearInstallations == [first, second])
    #expect(MachineConfiguration.settingLinearInstallation(second, inFileText: result) == result)
}

// MARK: - Whole-file renderers keep the registry

private func registryMachine() throws -> MachineConfiguration {
    try MachineConfiguration.parse(registryText, file: "config.toml")
}

@Test("a routing save keeps the registry")
func routingSaveKeepsRegistry() throws {
    let original = try registryMachine().declaring(cliAdapter: "claude", executable: "/bin/claude")
    let rendered = original.renderedTOML(routingTable: [
        RoutingEntryDraft(route: RouteDraft(cli: "claude", model: "opus", effort: "high"))
    ])
    let reparsed = try MachineConfiguration.parse(rendered, file: "config.toml")
    #expect(reparsed.linearInstallations == original.linearInstallations)
    #expect(reparsed.codeHostingConnections == original.codeHostingConnections)
    #expect(reparsed.linearInstallations.first?.operatorIdentity == BoardObjectID(rawValue: "old-user"))
    let order = [
        "[board.linear.connections.acme]", "[board.linear.connections.\"acme corp\"]",
        "[code_hosting.github.connections.github]"
    ]
    let positions = order.compactMap { rendered.range(of: $0)?.lowerBound }
    #expect(positions.count == order.count)
    #expect(positions == positions.sorted())
}

@Test("a CLI save keeps the registry")
func cliSaveKeepsRegistry() throws {
    let original = try registryMachine()
    let edited = original.declaring(cliAdapter: "claude", executable: "/opt/homebrew/bin/claude")
    let reparsed = try MachineConfiguration.parse(edited.renderedTOML, file: "config.toml")
    #expect(reparsed.linearInstallations == original.linearInstallations)
    #expect(reparsed.cliAdapters.map(\.name) == ["claude"])
}

@Test("a Configuration save keeps [board.linear]")
func configurationSaveKeepsBoardLinear() throws {
    let project = try testEditingProject(id: "keepboard")
    var draft = ProjectFileDraft(project)
    #expect(draft.linearInstallationName == "acme")
    let reparsed = try ProjectConfiguration.parse(draft.renderedTOML, file: "keepboard.toml")
    #expect(reparsed.linearInstallationName == "acme")
    #expect(reparsed.linearProject == project.linearProject)

    let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
    defer { cleanupEditingDirectory(directory) }
    let file = editingProjectFileURL(directory, "keepboard")
    let originalText = try String(contentsOf: file, encoding: .utf8)
    draft.name = "Renamed"
    try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
    let loaded = try #require(Configuration.load(directory: directory).projects.first)
    #expect(loaded.name == "Renamed")
    #expect(loaded.linearInstallationName == "acme")
    #expect(loaded.linearProject == project.linearProject)
}

@Test("a Configuration save of a Project naming an unregistered installation is refused")
func configurationSaveRefusesUnregisteredInstallation() throws {
    let project = try testEditingProject(id: "stray")
    let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
    defer { cleanupEditingDirectory(directory) }
    let file = editingProjectFileURL(directory, "stray")
    let originalText = try String(contentsOf: file, encoding: .utf8)
    var draft = ProjectFileDraft(project)
    draft.linearInstallationName = "missing"
    do {
        try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
        Issue.record("expected the save to be refused")
    } catch {
        guard case .refused(let errors) = error else {
            Issue.record("expected .refused, got \(error)")
            return
        }
        #expect(errors.map(\.reason) == [.undeclaredLinearInstallation("missing")])
        #expect(errors.first?.key == "board.linear.connection")
    }
}

@Test("a Configuration save keeps [code_hosting] and the registry; a draft edit carries the selection through")
func configurationSaveKeepsCodeHosting() throws {
    let project = try testEditingProject(id: "keepcode")
    var draft = ProjectFileDraft(project)
    #expect(draft.codeHostingConnectionName == "github")
    #expect(draft.renderedTOML.contains("[code_hosting]\nconnection = \"github\""))
    #expect(!draft.renderedTOML.contains("[github]"))
    let reparsed = try ProjectConfiguration.parse(draft.renderedTOML, file: "keepcode.toml")
    #expect(reparsed.codeHostingConnectionName == "github")

    let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
    defer { cleanupEditingDirectory(directory) }
    let file = editingProjectFileURL(directory, "keepcode")
    let originalText = try String(contentsOf: file, encoding: .utf8)
    draft.name = "Renamed"
    try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
    let loaded = try #require(Configuration.load(directory: directory).projects.first)
    #expect(loaded.name == "Renamed")
    #expect(loaded.codeHostingConnectionName == "github")
}

@Test("a Configuration save of a Project naming an unregistered Code Hosting Connection is refused")
func configurationSaveRefusesUnregisteredCodeHostingConnection() throws {
    let project = try testEditingProject(id: "straycode")
    let directory = try makeEditingDirectory(machine: try testEditingMachine(), projects: [project])
    defer { cleanupEditingDirectory(directory) }
    let file = editingProjectFileURL(directory, "straycode")
    let originalText = try String(contentsOf: file, encoding: .utf8)
    var draft = ProjectFileDraft(project)
    draft.codeHostingConnectionName = "missing"
    do {
        try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
        Issue.record("expected the save to be refused")
    } catch {
        guard case .refused(let errors) = error else {
            Issue.record("expected .refused, got \(error)")
            return
        }
        #expect(errors.map(\.reason) == [.undeclaredCodeHostingConnection("missing")])
        #expect(errors.first?.key == "code_hosting.connection")
    }
}

@Test("a draft with a non-default pull_request_title renders [github] with the title and nothing else")
func draftRendersTitleOnlyGitHubTable() throws {
    var project = try testEditingProject(id: "titled")
    project.pullRequestTitle = try MessageTemplate("[{key}] {title}", kind: .pullRequestTitle)
    let rendered = ProjectFileDraft(project).renderedTOML
    #expect(rendered.contains("[github]\npull_request_title = \"[{key}] {title}\"\n"))
    #expect(!rendered.contains("credential"))
    let reparsed = try ProjectConfiguration.parse(rendered, file: "titled.toml")
    #expect(reparsed == project)
}

@Test("the registry renders one table per connection: a gh entry holds no credential")
func registryRendersOneTablePerConnection() throws {
    let machine = MachineConfiguration(
        codeHostingConnections: [
            CodeHostingConnection(name: "acme", kind: .keychainToken(try credential("keychain:github-acme"))),
            CodeHostingConnection(name: "my gh", kind: .githubCLI(executable: nil))
        ],
        cliAdapters: [], routingTable: []
    )
    #expect(machine.renderedTOML == """
        [code_hosting.github.connections.acme]
        type = "keychain"
        credential = "keychain:github-acme"

        [code_hosting.github.connections."my gh"]
        type = "gh"

        """)
}
