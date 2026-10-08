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

    private static func configFileExists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(component: "config.toml").path(percentEncoded: false)
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
        #expect(error.message.contains("yh setup --install-github"))
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

    @Test("--github-credential that differs from the kept config.toml is noted, and the kept one is used")
    func initKeptConfigurationReferenceWins() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let output = RecordingOutput()
        let transport = StubGitHubTransport.passing()
        let setup = try makeSetup(
            arguments: Self.initArguments() + ["--board-connection", "acme", "--github-credential", "keychain:other"],
            directory: directory, board: await makeBoard(project: nil), output: output,
            gitHub: transport.validation()
        )

        try await setup.run()

        #expect(output.lines.contains { $0.hasPrefix("note: ") && $0.contains("keychain:other") })
        #expect(output.lines.contains { $0.contains("keychain:github is in the Keychain") })
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

    // MARK: Interactive

    private func interactive(
        credentials: RecordingCredentialStore, transport: StubGitHubTransport,
        console: ScriptedConsole,
        importer: @escaping @Sendable () async -> GitHubTokenImport = { .unavailable("no gh") },
        output: RecordingOutput = RecordingOutput(), directory: borrowing ConfigurationDirectory
    ) async throws -> Setup {
        try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: await makeBoard(), console: console, credentials: credentials, output: output,
            gitHub: transport.validation(), importGitHubToken: importer
        )
    }

    /// GitHub credential, CLI Adapters and catch-all route, then (after the GitHub step) the Linear
    /// install question, the local name, and "Declare a Project now?".
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
        let console = ScriptedConsole(answers: ["", "", "", nil])
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

    // MARK: Install

    private func install(
        _ extra: [String], credentials: RecordingCredentialStore, transport: StubGitHubTransport,
        console: ScriptedConsole = ScriptedConsole(), output: RecordingOutput = RecordingOutput(),
        importer: @escaping @Sendable () async -> GitHubTokenImport = { .unavailable("gh is not installed") },
        directory: borrowing ConfigurationDirectory
    ) async throws -> Setup {
        try makeSetup(
            arguments: ["--install-github"] + extra, directory: directory, board: await makeBoard(),
            console: console, credentials: credentials, output: output, gitHub: transport.validation(),
            importGitHubToken: importer
        )
    }

    @Test("--install-github --token-stdin reads one line, validates, stores, and creates no config.toml")
    func installTokenStdin() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let console = ScriptedConsole(answers: ["  ghp_stdin \n"])
        let transport = StubGitHubTransport.passing()
        let setup = try await install(
            ["--token-stdin", "--github-repo", "~/dev/demo-backend"], credentials: credentials,
            transport: transport, console: console, directory: directory
        )

        try await setup.run()

        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_stdin")])
        #expect(console.prompts == [""])
        #expect(transport.paths.contains("/repos/acme/demo-backend"))
        #expect(!Self.configFileExists(directory.url))
    }

    @Test("--install-github --token-stdin with an empty line fails and stores nothing")
    func installTokenStdinEmpty() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let setup = try await install(
            ["--token-stdin"], credentials: credentials, transport: StubGitHubTransport.passing(),
            console: ScriptedConsole(answers: ["  "]), directory: directory
        )

        #expect(await failure(setup) != nil)
        #expect(credentials.storedSecrets.isEmpty)
    }

    @Test("--install-github with a rejected token stores nothing and fails")
    func installRejected() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["ghp_good"])
        let setup = try await install(
            ["--token-stdin"], credentials: credentials, transport: transport,
            console: ScriptedConsole(answers: ["ghp_bad"]), directory: directory
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("rejected"))
        #expect(!error.message.contains("ghp_bad"))
        #expect(credentials.storedSecrets.isEmpty)
    }

    @Test("--install-github --replace asks for a token even when the stored one works")
    func installReplace() async throws {
        let directory = ConfigurationDirectory()
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole(answers: ["ghp_new"])
        let setup = try await install(
            ["--replace"], credentials: credentials, transport: StubGitHubTransport.passing(),
            console: console, directory: directory
        )

        try await setup.run()

        #expect(console.prompts == [Self.secretPrompt])
        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_new")])
    }

    @Test("--install-github against a stored valid token asks nothing and stores nothing")
    func installExistingValid() async throws {
        let directory = ConfigurationDirectory()
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole()
        let output = RecordingOutput()
        let setup = try await install(
            ["--github-credential", "keychain:github"], credentials: credentials,
            transport: StubGitHubTransport.passing(), console: console, output: output, directory: directory
        )

        try await setup.run()

        #expect(console.prompts.isEmpty)
        #expect(credentials.storedSecrets.isEmpty)
        #expect(output.lines.contains { $0.contains("is in the Keychain (GitHub user octocat)") })
    }

    @Test("--install-github --from-gh stores the imported token")
    func installFromGitHubCLI() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let setup = try await install(
            ["--from-gh"], credentials: credentials, transport: StubGitHubTransport.passing(),
            importer: { .token("gho_from_gh") }, directory: directory
        )

        try await setup.run()

        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "gho_from_gh")])
    }

    @Test("--install-github --from-gh with no gh fails with the reason")
    func installFromGitHubCLIUnavailable() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let setup = try await install(
            ["--from-gh"], credentials: credentials, transport: StubGitHubTransport.passing(),
            importer: { .unavailable("run gh auth login first") }, directory: directory
        )

        let error = try #require(await failure(setup))

        #expect(error.message.contains("run gh auth login first"))
        #expect(credentials.storedSecrets.isEmpty)
    }

    @Test("A stored token whose Repo check then fails stays stored, and the run fails naming each Repo")
    func installRepoFailureKeepsToken() async throws {
        let directory = ConfigurationDirectory()
        let credentials = Self.withoutGitHub()
        let transport = StubGitHubTransport.passing(routes: [
            "/repos/acme/demo-backend": .repo(push: false), "/repos/acme/demo-mobile": .notFound
        ])
        let setup = try await install(
            ["--token-stdin", "--github-repo", "~/dev/demo-backend", "--github-repo", "~/dev/demo-mobile"],
            credentials: credentials, transport: transport, console: ScriptedConsole(answers: ["ghp_stdin"]),
            directory: directory
        )

        let error = try #require(await failure(setup))

        #expect(credentials.storedSecrets == [.init(reference: "keychain:github", secret: "ghp_stdin")])
        #expect(error.message.contains("Repo demo-backend (acme/demo-backend): the token lacks push permission"))
        #expect(error.message.contains("Repo demo-mobile (acme/demo-mobile): not found or not accessible"))
    }

    @Test("Without --github-repo, --install-github checks the working Repos of the Projects using the reference")
    func installChecksConfiguredProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "demo", repoPath: "~/dev/demo-backend")
        let transport = StubGitHubTransport.passing()
        let setup = try await install(
            [], credentials: RecordingCredentialStore.withGitHub(), transport: transport, directory: directory
        )

        try await setup.run()

        #expect(transport.paths.contains("/repos/acme/demo-backend"))
    }

    // MARK: Print

    @Test("--print-github prints one decodable line, never prompts, and stores nothing")
    func printGitHub() async throws {
        let directory = ConfigurationDirectory()
        let credentials = RecordingCredentialStore.withGitHub()
        let console = ScriptedConsole()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-github", "--github-repo", "~/dev/demo-backend"], directory: directory,
            board: await makeBoard(), console: console, credentials: credentials, output: output,
            gitHub: StubGitHubTransport.passing().validation()
        )

        try await setup.run()

        #expect(output.lines.count == 1)
        let report = try #require(GitHubCredentialReport.decodeLastLine(output.lines))
        #expect(report.state == .resolves)
        #expect(report.login == "octocat")
        #expect(report.repos.map(\.status) == [.ok])
        #expect(console.prompts.isEmpty)
        #expect(credentials.storedSecrets.isEmpty)
        #expect(!Self.configFileExists(directory.url))
    }

    @Test("--print-github exits 0 with an invalid report")
    func printGitHubInvalid() async throws {
        let directory = ConfigurationDirectory()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-github"], directory: directory, board: await makeBoard(),
            credentials: Self.withoutGitHub(), output: output, gitHub: StubGitHubTransport.passing().validation()
        )

        try await setup.run()

        let report = try #require(GitHubCredentialReport.decodeLastLine(output.lines))
        #expect(report.state == .missing)
        #expect(!report.isValid)
    }

    // MARK: Option combinations

    @Test("Invalid GitHub option combinations are refused", arguments: [
        ["--install-github", "--print-github"],
        ["--install-github", "--init"],
        ["--install-github", "--config", "/tmp/x"],
        ["--install-github", "--install-linear"],
        ["--install-github", "--print-choices"],
        ["--install-github", "--project", "demo"], // glossary:ignore GL001
        ["--install-github", "--cli", "claude"],
        ["--install-github", "--route", "claude/opus/high"],
        ["--install-github", "--install-jobs"],
        ["--install-github", "--export-jobs", "/tmp/jobs"],
        ["--print-github", "--init"],
        ["--print-github", "--config", "/tmp/x"],
        ["--print-github", "--install-linear"],
        ["--print-github", "--print-choices"],
        ["--print-github", "--project", "demo"], // glossary:ignore GL001
        ["--print-github", "--cli", "claude"],
        ["--print-github", "--route", "claude/opus/high"],
        ["--print-github", "--install-jobs"],
        ["--install-github", "--token-stdin", "--from-gh"],
        ["--print-github", "--token-stdin"],
        ["--print-github", "--from-gh"],
        ["--print-github", "--replace"],
        ["--token-stdin"],
        ["--from-gh"],
        ["--replace"],
        ["--init", "--token-stdin"],
        ["--github-repo", "~/dev/backend"],
        ["--init", "--github-repo", "~/dev/backend"]
    ])
    func combinationsRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try SetupOptions(command: try SetupCommand.parse(arguments)) }
    }

    @Test("Valid GitHub option combinations parse")
    func combinationsAccepted() throws {
        for arguments in [
            ["--install-github"],
            ["--install-github", "--token-stdin", "--replace", "--github-repo", "~/a"],
            ["--install-github", "--from-gh", "--github-credential", "keychain:x"],
            ["--print-github"],
            ["--print-github", "--github-repo", "~/a", "--github-repo", "~/b"]
        ] {
            _ = try SetupOptions(command: try SetupCommand.parse(arguments))
        }
    }
}
