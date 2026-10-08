import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// The Code Hosting Connection registry in `yh setup` (connect-code-hosting): which connection a written
/// Project selects, and `--install-github` / `--print-github` acting on a named connection.
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
        #expect(error.message.contains("yh setup --install-github"))
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
            $0.contains("`yh setup --install-github --code-hosting-connection gh` passes for its Repos")
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

    // MARK: - --install-github

    private func install(
        _ extra: [String], directory: borrowing ConfigurationDirectory,
        credentials: RecordingCredentialStore, transport: StubGitHubTransport = StubGitHubTransport.passing(),
        console: ScriptedConsole = ScriptedConsole(), output: RecordingOutput = RecordingOutput()
    ) async throws -> Setup {
        try makeSetup(
            arguments: ["--install-github"] + extra, directory: directory, board: await makeBoard(),
            console: console, credentials: credentials, output: output, gitHub: transport.validation()
        )
    }

    @Test("--install-github --code-hosting-connection N adds N only after the token is accepted, and is idempotent")
    func installAddsAfterAcceptance() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["ghp_good"])

        let rejected = try await install(
            ["--code-hosting-connection", "extra", "--token-stdin"], directory: directory,
            credentials: credentials, transport: transport, console: ScriptedConsole(answers: ["ghp_bad"])
        )
        let error = try #require(await failure(rejected))
        #expect(error.message.contains("rejected"))
        #expect(credentials.storedSecrets.isEmpty)
        #expect(try Self.read(directory.url, "config.toml") == Self.registry)

        let output = RecordingOutput()
        let accepted = try await install(
            ["--code-hosting-connection", "extra", "--token-stdin"], directory: directory,
            credentials: credentials, transport: transport, console: ScriptedConsole(answers: ["ghp_good"]),
            output: output
        )
        try await accepted.run()
        let afterFirst = try Self.read(directory.url, "config.toml")
        #expect(credentials.storedSecrets == [.init(reference: "keychain:extra", secret: "ghp_good")])
        #expect(afterFirst.hasPrefix(Self.registry))
        #expect(afterFirst.contains("[code_hosting.github.connections.extra]\ntype = \"keychain\""))
        #expect(output.lines.contains("Code Hosting Connection extra is ready."))

        let again = try await install(
            ["--code-hosting-connection", "extra"], directory: directory, credentials: credentials,
            transport: transport
        )
        try await again.run()
        #expect(try Self.read(directory.url, "config.toml") == afterFirst)
        #expect(credentials.storedSecrets.count == 1)
    }

    @Test("--install-github with a new name needs a valid local name, and a gh connection is refused")
    func installNameAndKindChecks() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let credentials = Self.credentials()

        let invalid = try await install(
            ["--code-hosting-connection", "Bad Name", "--token-stdin"], directory: directory,
            credentials: credentials, console: ScriptedConsole(answers: ["ghp_x"])
        )
        let invalidError = try #require(await failure(invalid))
        #expect(invalidError.message.contains("is not a valid Code Hosting Connection name"))

        let gh = try await install(
            ["--code-hosting-connection", "gh", "--token-stdin"], directory: directory,
            credentials: credentials, console: ScriptedConsole(answers: ["ghp_x"])
        )
        let ghError = try #require(await failure(gh))
        #expect(ghError.message == CodeHostingRefusal.githubCLINotSupported(connection: "gh").description)

        #expect(credentials.storedSecrets.isEmpty)
        #expect(try Self.read(directory.url, "config.toml") == Self.registry)
    }

    @Test("--install-github refuses a config.toml that does not load, before capturing, and leaves it untouched")
    func installRefusesBrokenMachineFile() async throws {
        let directory = ConfigurationDirectory()
        let broken = "[github]\ncredential = \"keychain:github\"\n"
        try directory.writeMachineFile(broken)
        let credentials = Self.credentials()
        let console = ScriptedConsole(answers: ["ghp_x"])
        let transport = StubGitHubTransport.passing()
        let setup = try await install(
            ["--token-stdin"], directory: directory, credentials: credentials, transport: transport,
            console: console
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("is invalid"))
        #expect(console.prompts.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(credentials.storedSecrets.isEmpty)
        #expect(try Self.read(directory.url, "config.toml") == broken)
    }

    // MARK: - --print-github

    private func printed(
        _ extra: [String], directory: borrowing ConfigurationDirectory, credentials: RecordingCredentialStore,
        transport: StubGitHubTransport = StubGitHubTransport.passing()
    ) async throws -> GitHubCredentialReport {
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-github"] + extra, directory: directory, board: await makeBoard(),
            credentials: credentials, output: output, gitHub: transport.validation()
        )
        try await setup.run()
        return try #require(GitHubCredentialReport.decodeLastLine(output.lines))
    }

    @Test("--print-github on a connection that is not connected reports missing, whatever the Keychain holds")
    func printUnknownConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let transport = StubGitHubTransport.passing()

        let report = try await printed(
            ["--code-hosting-connection", "stray"], directory: directory,
            credentials: RecordingCredentialStore.withGitHub(["keychain:stray": "ghp_stray"]), transport: transport
        )

        #expect(report.state == .missing)
        #expect(report.reference == "keychain:stray")
        #expect(report.message.contains("No Code Hosting Connection named stray is connected"))
        #expect(report.message.contains("yh setup --install-github --code-hosting-connection stray"))
        #expect(transport.requests.isEmpty)
        #expect(!Self.exists(directory.url, "projects"))
    }

    @Test("--print-github with no config.toml reports the default connection as missing, even with a token")
    func printWithoutMachineFile() async throws {
        let directory = ConfigurationDirectory()

        let report = try await printed([], directory: directory, credentials: Self.credentials())

        #expect(report.state == .missing)
        #expect(report.reference == "keychain:github")
        #expect(!Self.exists(directory.url, "config.toml"))
    }

    @Test("--print-github on a gh CLI connection reports missing with the resolver's description")
    func printGitHubCLIConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)

        let report = try await printed(
            ["--code-hosting-connection", "gh"], directory: directory, credentials: Self.credentials()
        )

        #expect(report.state == .missing)
        #expect(report.message == CodeHostingRefusal.githubCLINotSupported(connection: "gh").description)
    }

    @Test("--print-github on a Keychain token connection checks that connection's reference")
    func printKeychainConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.registry)
        let transport = StubGitHubTransport.passing()

        let report = try await printed(
            ["--code-hosting-connection", "work"], directory: directory,
            credentials: RecordingCredentialStore(seed: ["keychain:github-work": "ghp_work"]), transport: transport
        )

        #expect(report.state == .resolves)
        #expect(report.reference == "keychain:github-work")
        #expect(transport.bearerTokens.allSatisfy { $0 == "ghp_work" })
    }
}
