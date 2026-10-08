import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// The Code Hosting Connection registry in `yh setup` (connect-code-hosting): which connection a written
/// Project selects and the setup flow choosing a named connection.
@Suite("yh setup, Code Hosting Connections")
struct SetupCodeHostingTests {
    private static let backend = "backend,backend,~/dev/demo-backend,swift test"
    private static let secretPrompt = "GitHub token (input hidden): "

    /// Linear acme plus a `github` and a `work` Keychain token connection and a `gh` CLI one.
    private static let registry = ConfigurationDirectory.machineFile + """


        [code_hosting.github.connections.work]
        type = "keychain"
        credential = "keychain:github-work"

        [code_hosting.github.connections.gh]
        type = "gh"
        """

    /// The Keychain items a run needs: the Linear Board Connection's tokens and the `github` token.
    private static func credentials(_ more: [String: String] = [:]) -> RecordingCredentialStore {
        RecordingCredentialStore(
            seed: [
                "keychain:linear": "test-secret", "keychain:linear-acme": "test-secret",
                "keychain:github": "ghp_test"
            ].merging(more) { $1 }
        )
    }

    private static func initArguments(
        connection: String? = nil, omitConnection: Bool = false, extra: [String] = []
    ) -> [String] {
        makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG", specSource: "~/dev/demo-spec",
            repo: [backend], installation: "acme", codeHostingConnection: connection,
            omitCodeHostingConnection: omitConnection
        ) + extra
    }

    private static func read(_ directory: URL, _ components: String...) throws -> String {
        try String(
            contentsOf: components.reduce(directory) { $0.appending(component: $1) }, encoding: .utf8
        )
    }

    private static func exists(_ directory: URL, _ components: String...) -> Bool {
        FileManager.default.fileExists(
            atPath: components.reduce(directory) { $0.appending(component: $1) }.path(percentEncoded: false)
        )
    }

    private func failure(_ setup: Setup) async -> SetupError? {
        do {
            try await setup.run()
            return nil
        } catch {
            return error as? SetupError
        }
    }

    // MARK: - --init --project

    @Test("--init --project without --code-hosting-connection is refused before Linear") // glossary:ignore GL001
    func initRequiresTheConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let board = await makeBoard(project: nil)
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: Self.initArguments(omitConnection: true), directory: directory, board: board,
            gitHub: transport.validation()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("--code-hosting-connection"))
        #expect(error.message.contains("github, work, gh"))
        #expect(await board.creates == 0)
        #expect(!Self.exists(directory.url, "projects", "demo.toml"))
        #expect(transport.requests.isEmpty)
    }

    @Test("--init --project with an empty registry says how to connect the first connection") // glossary:ignore GL001
    func initWithEmptyRegistry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("")
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(
            arguments: Self.initArguments(omitConnection: true).filter { $0 != "--board-connection" && $0 != "acme" },
            directory: directory, board: board
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("none are connected"))
        #expect(error.message.contains("yh config connect-code-hosting github --token-stdin"))
        #expect(await board.creates == 0)
    }

    @Test("--init --project naming an unknown connection is refused, listing the names") // glossary:ignore GL001
    func initUnknownConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(
            arguments: Self.initArguments(connection: "nope"), directory: directory, board: board
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("nope is not a connected Code Hosting Connection"))
        #expect(error.message.contains("connected: github, work, gh"))
        #expect(await board.creates == 0)
        #expect(!Self.exists(directory.url, "projects", "demo.toml"))
    }

    @Test("--init --project writes the selection and checks the token of that connection") // glossary:ignore GL001
    func initWritesTheSelection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials(["keychain:github-work": "ghp_work"])
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: Self.initArguments(connection: "work"), directory: directory,
            board: await makeBoard(project: nil), credentials: credentials, gitHub: transport.validation()
        )

        try await setup.run()

        let text = try Self.read(directory.url, "projects", "demo.toml")
        #expect(text.contains("[code_hosting]\nconnection = \"work\""))
        #expect(!text.contains("credential"))
        #expect(!transport.bearerTokens.isEmpty)
        #expect(transport.bearerTokens.allSatisfy { $0 == "ghp_work" })
        let configuration = try Configuration.load(directory: directory.url)
        #expect(configuration.projects.first?.codeHostingConnectionName == "work")
    }

    @Test("--init --project with a gh CLI connection is refused with its description") // glossary:ignore GL001
    func initGitHubCLIConnectionRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(
            arguments: Self.initArguments(connection: "gh"), directory: directory, board: board
        )

        let error = try #require(await failure(setup))

        #expect(error.message == CodeHostingRefusal.githubCLINotSupported(connection: "gh").description)
        #expect(await board.creates == 0)
        #expect(!Self.exists(directory.url, "projects", "demo.toml"))
    }

    @Test("--skip-github-check still requires a connected connection, and skips only the token check")
    func skipStillRequiresMembership() async throws {
        let unknown = ConfigurationDirectory()
        try unknown.writeMachineFile(Self.registry)
        let board = await makeBoard(project: nil)
        let refused = try makeSetup(
            arguments: Self.initArguments(connection: "nope", extra: ["--skip-github-check"]),
            directory: unknown, board: board
        )
        let error = try #require(await failure(refused))
        #expect(error.message.contains("nope is not a connected Code Hosting Connection"))
        #expect(await board.creates == 0)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: Self.initArguments(connection: "gh", extra: ["--skip-github-check"]),
            directory: directory, board: await makeBoard(project: nil), output: output,
            gitHub: transport.validation()
        )

        try await setup.run()

        #expect(transport.requests.isEmpty)
        #expect(try Self.read(directory.url, "projects", "demo.toml").contains("connection = \"gh\""))
        #expect(output.lines.contains {
            $0.contains(
                "`yh config check-code-hosting-credential --connection gh` passes for its Repos"
            )
        })
    }

    // MARK: - Interactive

    @Test("Interactive: an existing connection is chosen by number and nothing is stored")
    func interactiveChoosesExisting() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials(["keychain:github-work": "ghp_work"])
        let console = ScriptedConsole(answers: ["9", "", "2", "n"]) // out of range, empty, work, no Project now
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(), console: console, credentials: credentials,
            output: output, gitHub: StubGitHubTransport.passing().validation()
        )

        try await setup.run()

        #expect(output.lines.contains("  1) github — Keychain token"))
        #expect(output.lines.contains("  2) work — Keychain token"))
        #expect(output.lines.contains("  3) gh — gh CLI"))
        #expect(output.lines.contains("  4) Connect a GitHub token (Keychain)…"))
        #expect(credentials.storedSecrets.isEmpty)
        #expect(console.prompts.filter { $0 == "Choose [1-4]: " }.count == 3)
    }

    @Test("Interactive: choosing a gh CLI connection is refused with its description and asks again")
    func interactiveGitHubCLIAsksAgain() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let console = ScriptedConsole(answers: ["3", "1", "n"])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(), console: console,
            credentials: Self.credentials(), output: output,
            gitHub: StubGitHubTransport.passing().validation()
        )

        try await setup.run()

        #expect(output.lines.contains(CodeHostingRefusal.githubCLINotSupported(connection: "gh").description))
        #expect(console.prompts.filter { $0 == "Choose [1-4]: " }.count == 2)
    }

    @Test("Interactive: a new connection is named, its token stored, and the entry added after GitHub accepts it")
    func interactiveConnectsNew() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials()
        let console = ScriptedConsole(answers: [
            "4", // Connect a GitHub token (Keychain)…
            "", // github is taken, so there is no default: re-asks
            "Bad Name", // not a valid local name: re-asks
            "work", // taken: re-asks
            "extra", // free
            "ghp_extra", // the token
            "n" // no Project now
        ])
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(), console: console, credentials: credentials,
            output: output, gitHub: transport.validation()
        )

        try await setup.run()

        #expect(credentials.storedSecrets == [.init(reference: "keychain:extra", secret: "ghp_extra")])
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.codeHostingConnection(named: "extra")?.kind == .keychainToken(
            CodeHostingConnection.defaultCredentialReference(for: "extra")
        ))
        #expect(machine.codeHostingConnections.map(\.name) == ["github", "work", "gh", "extra"])
        #expect(output.lines.contains { $0.contains("is not a valid Code Hosting Connection name") })
        #expect(output.lines.contains("a Code Hosting Connection named work is already connected"))
    }

    @Test("Interactive: a token GitHub rejects adds no connection")
    func interactiveRejectedTokenAddsNothing() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials()
        let console = ScriptedConsole(answers: ["4", "extra", "ghp_bad", nil]) // rejected, then EOF cancels
        let transport = StubGitHubTransport.passing(acceptedTokens: ["ghp_good"])
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(), console: console, credentials: credentials,
            gitHub: transport.validation()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("cancelled"))
        #expect(credentials.storedSecrets.isEmpty)
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.codeHostingConnection(named: "extra") == nil)
    }

    @Test("Interactive: an empty registry goes straight to connecting, without a list")
    func interactiveEmptyRegistryConnects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"
            """)
        let credentials = RecordingCredentialStore(
            seed: ["keychain:linear": "test-secret", "keychain:linear-acme": "test-secret"]
        )
        let console = ScriptedConsole(answers: ["", "ghp_first", "n"]) // default name, token, no Project now
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(), console: console, credentials: credentials,
            output: output, gitHub: StubGitHubTransport.passing().validation()
        )

        try await setup.run()

        #expect(!output.lines.contains("Code Hosting Connections:"))
        #expect(console.prompts.first == "Local name for this connection [github]: ")
        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_first")])
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.codeHostingConnections.map(\.name) == ["github"])
    }

    @Test("Interactive --code-hosting-connection must name a connected connection")
    func interactiveGivenUnknown() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", codeHostingConnection: "nope"
            ),
            directory: directory, board: await makeBoard()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("nope is not a connected Code Hosting Connection"))
    }
}
