import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// The GitHub step of `yh setup`: capture, check and store the token before a Project is written.
@Suite("yh setup, GitHub credential")
struct SetupGitHubTests {
    private static let backend = "backend,backend,~/dev/demo-backend,swift test"
    private static let mobile = "mobile,mobile,~/dev/demo-mobile,swift test"
    private static let secretPrompt = "GitHub token (input hidden): "
    private static let cliPrompt = "Use the token from the GitHub CLI (gh)? [Y/n] "

    /// Linear is installed; no GitHub token is.
    private static func withoutGitHub() -> RecordingCredentialStore {
        RecordingCredentialStore(seed: ["keychain:linear": "test-secret", "keychain:linear-acme": "test-secret"])
    }

    private static func initArguments(
        repos: [String] = [backend], specSource: String? = "~/dev/demo-spec"
    ) -> [String] {
        makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG", specSource: specSource, repo: repos
        )
    }

    private static func projectFileExists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(components: "projects", "demo.toml").path(percentEncoded: false)
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

    // MARK: Init

    @Test("--init --project, no stored token: fails, no Project file, no Linear project") // glossary:ignore GL001
    func initMissingItem() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: Self.initArguments(), directory: directory, board: board,
            credentials: Self.withoutGitHub(), gitHub: transport.validation()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("No GitHub token is stored for keychain:github"))
        #expect(error.message.contains("yh config replace-code-hosting-token github --token-stdin"))
        #expect(!Self.projectFileExists(directory.url))
        #expect(await board.creates == 0)
        #expect(transport.requests.isEmpty)
    }

    @Test("--init --project, token rejected: fails, writes and creates nothing") // glossary:ignore GL001
    func initRejectedToken() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let transport = StubGitHubTransport.passing(routes: ["/user": .unauthorized])
        let setup = try makeSetup(
            arguments: Self.initArguments(), directory: directory, board: board, gitHub: transport.validation()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("rejected"))
        #expect(!error.message.contains("ghp_test"))
        #expect(!Self.projectFileExists(directory.url))
        #expect(await board.creates == 0)
    }

    @Test("A Repo the token cannot push to fails the run, naming that Repo and the permission")
    func initNoPushOnOneRepo() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/demo-mobile": .repo(push: false)])
        let setup = try makeSetup(
            arguments: Self.initArguments(repos: [Self.backend, Self.mobile]), directory: directory, board: board,
            gitHub: transport.validation()
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("Repo mobile (acme/demo-mobile): the token lacks push permission"))
        #expect(!error.message.contains("Repo backend"))
        #expect(!Self.projectFileExists(directory.url))
        #expect(await board.creates == 0)
    }

    @Test("A Repo of role spec is not checked")
    func initSpecRepoNotChecked() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/demo-spec": .repo(push: false)])
        let setup = try makeSetup(
            arguments: Self.initArguments(repos: [Self.backend, "spec,spec,~/dev/demo-spec,none"], specSource: nil),
            directory: directory, board: board, gitHub: transport.validation()
        )

        try await setup.run()

        #expect(Self.projectFileExists(directory.url))
        #expect(transport.paths.contains("/repos/acme/demo-backend"))
        #expect(!transport.paths.contains("/repos/acme/demo-spec"))
    }

    @Test("An existing valid token completes without a prompt, says so, and the token goes nowhere but GitHub")
    func initExistingValidToken() async throws {
        let directory = ConfigurationDirectory()
        let console = ScriptedConsole()
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing()
        let credentials = RecordingCredentialStore.withGitHub()
        let setup = try makeSetup(
            arguments: Self.initArguments(), directory: directory, board: await makeBoard(project: nil),
            console: console, credentials: credentials, output: output, gitHub: transport.validation()
        )

        try await setup.run()

        #expect(console.prompts.isEmpty)
        #expect(output.lines.contains("GitHub credential keychain:github is in the Keychain (GitHub user octocat)"))
        #expect(credentials.storedSecrets.isEmpty)
        #expect(Self.projectFileExists(directory.url))
        #expect(!output.lines.contains { $0.contains("ghp_test") })
    }

    @Test("--init without --project runs no GitHub step") // glossary:ignore GL001
    func initWithoutProjectSkipsGitHub() async throws {
        let directory = ConfigurationDirectory()
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: ["--init", "--operator", "user-op"], directory: directory, board: await makeBoard(),
            credentials: Self.withoutGitHub(), gitHub: transport.validation()
        )

        try await setup.run()

        #expect(transport.requests.isEmpty)
    }

    @Test("--skip-github-check writes the Project with no token, warns once, and never calls GitHub")
    func initSkipGitHubCheck() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: Self.initArguments() + ["--skip-github-check"], directory: directory, board: board,
            credentials: Self.withoutGitHub(), output: output, gitHub: transport.validation()
        )

        try await setup.run()

        #expect(Self.projectFileExists(directory.url))
        #expect(transport.requests.isEmpty)
        let warnings = output.lines.filter { $0.contains("the GitHub check was skipped") }
        #expect(warnings == [
            "warning: the GitHub check was skipped (--skip-github-check): `land` cannot push or open pull "
                + "requests for Project demo until "
                + "`yh config check-code-hosting-credential --connection github` passes for its Repos; "
                + "`yh doctor` reports it."
        ])
    }

    @Test("Interactive --skip-github-check asks for no token and checks nothing")
    func interactiveSkipGitHubCheck() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: ["1", "n"]) // the only connection, then no Project now
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ) + ["--skip-github-check"],
            directory: directory, board: await makeBoard(), console: console, credentials: credentials,
            gitHub: transport.validation()
        )

        try await setup.run()

        #expect(!console.prompts.contains(Self.secretPrompt))
        #expect(!console.prompts.contains { $0.contains("Connect a GitHub token") })
        #expect(transport.requests.isEmpty)
        #expect(credentials.storedSecrets.isEmpty)
    }

    // MARK: Interactive

    private func interactive(
        credentials: RecordingCredentialStore, transport: StubGitHubTransport,
        console: ScriptedConsole,
        importer: @escaping @Sendable () async -> GitHubTokenImport = { .unavailable("no gh") },
        output: RecordingOutput = RecordingOutput(), directory: borrowing ConfigurationDirectory
    ) async throws -> Setup {
        try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", omitCodeHostingConnection: true),
            directory: directory,
            board: await makeBoard(), console: console, credentials: credentials, output: output,
            gitHub: transport.validation(), importGitHubToken: importer
        )
    }

    /// CLI Adapters, catch-all route and the new Code Hosting Connection's name (default `github`), then the
    /// GitHub step's answers, then the Linear install question, the local name and "Declare a Project now?".
    private static func answers(github: [String?]) -> [String?] {
        ["", "", ""] + github + ["", "", "n"]
    }

    @Test("Interactive with no stored token asks with hidden input, authenticates, and stores it")
    func interactiveMissingItem() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: Self.answers(github: ["  ghp_good  "]))
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing()
        let setup = try await interactive(
            credentials: credentials, transport: transport, console: console,
            output: output, directory: directory
        )

        try await setup.run()

        #expect(console.prompts.filter { $0 == Self.secretPrompt }.count == 1)
        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_good")])
        #expect(transport.bearerTokens.allSatisfy { $0 == "ghp_good" })
        #expect(output.lines.contains { $0.contains("service dev.yellowhammer, account github") })
        #expect(output.lines.contains { $0.contains("Always Allow") })
        #expect(!output.lines.contains { $0.contains("ghp_good") })
        #expect(!console.prompts.contains { $0.contains("ghp_good") })
    }

    @Test("A token GitHub rejects is not stored, and the Operator is asked again")
    func interactiveRejectedThenGood() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: Self.answers(github: ["ghp_bad", "ghp_good"]))
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["ghp_good"])
        let setup = try await interactive(
            credentials: credentials, transport: transport, console: console,
            output: output, directory: directory
        )

        try await setup.run()

        #expect(console.prompts.filter { $0 == Self.secretPrompt }.count == 2)
        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_good")])
        #expect(output.lines.contains { $0.contains("rejected that token") && $0.contains("not stored") })
    }

    @Test("EOF at the token prompt cancels setup and stores nothing")
    func interactiveEOFCancels() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: ["", "", "", nil]) // CLI, route, connection name, then EOF
        let setup = try await interactive(
            credentials: credentials, transport: StubGitHubTransport.passing(), console: console,
            directory: directory
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("cancelled"))
        #expect(credentials.storedSecrets.isEmpty)
    }

    @Test("The GitHub CLI's token is offered and, accepted, stored without a hidden prompt")
    func interactiveGitHubCLIAccepted() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: Self.answers(github: [""]))
        let setup = try await interactive(
            credentials: credentials, transport: StubGitHubTransport.passing(), console: console,
            importer: { .token("gho_from_gh") }, directory: directory
        )

        try await setup.run()

        #expect(console.prompts.contains(Self.cliPrompt))
        #expect(!console.prompts.contains(Self.secretPrompt))
        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "gho_from_gh")])
    }

    @Test("Declining the GitHub CLI's token falls back to the hidden prompt")
    func interactiveGitHubCLIDeclined() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: Self.answers(github: ["n", "ghp_typed"]))
        let setup = try await interactive(
            credentials: credentials, transport: StubGitHubTransport.passing(), console: console,
            importer: { .token("gho_from_gh") }, directory: directory
        )

        try await setup.run()

        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_typed")])
    }

    @Test("An interactive run with a stored valid token never asks for a secret")
    func interactiveExistingValidToken() async throws {
        let directory = ConfigurationDirectory()
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole(answers: Self.answers(github: []))
        let setup = try await interactive(
            credentials: credentials, transport: StubGitHubTransport.passing(), console: console,
            importer: { .token("gho_from_gh") }, directory: directory
        )

        try await setup.run()

        #expect(!console.prompts.contains(Self.secretPrompt))
        #expect(!console.prompts.contains(Self.cliPrompt))
        #expect(credentials.storedSecrets.isEmpty)
    }
}
