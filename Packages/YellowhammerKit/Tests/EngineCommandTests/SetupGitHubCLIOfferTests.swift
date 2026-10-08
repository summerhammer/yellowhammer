import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// Interactive `yh setup` offering the `gh` CLI as a Code Hosting Connection: only when gh resolves and is
/// logged in, never added unless the Operator picks it, and pre-selected once it is in the registry.
@Suite("yh setup, offering the gh CLI connection")
struct SetupGitHubCLIOfferTests {
    private static let board = """
        [board.linear.connections.acme]
        credential = "keychain:linear"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        """

    private static let keychainGitHub = """


        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"
        """

    private static let gitHubCLIEntry = """


        [code_hosting.github.connections.gh]
        type = "gh"
        """

    private static let declareProject = [
        "y", "demo", "", "", "1", "~/dev/demo-spec", "backend", "~/dev/demo-backend", "backend", "swift test", "n", "n"
    ]

    /// What a run left behind, read while its configuration directory still exists.
    private struct Outcome {
        let prompts: [String]
        let error: SetupError?
        let connections: [CodeHostingConnection]
        let projectText: String?
    }

    private func run(
        machine: String, answers: [String?], gh: StubGitHubCLI, found: Bool = true, skipGitHubCheck: Bool = false,
        output: RecordingOutput = RecordingOutput()
    ) async throws -> Outcome {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(machine)
        let console = ScriptedConsole(answers: answers)
        let credentials = RecordingCredentialStore(
            seed: [
                "keychain:linear": "test-secret", "keychain:linear-acme": "test-secret", "keychain:github": "ghp_test"
            ]
        )
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installation: "acme", omitCodeHostingConnection: true
            ) + (skipGitHubCheck ? ["--skip-github-check"] : []),
            directory: directory, board: await makeBoard(project: nil), console: console,
            credentials: credentials, output: output,
            gitHub: found ? gh.validation() : StubGitHubTransport.passing().validation()
        )
        var failure: SetupError?
        do {
            try await setup.run()
        } catch {
            failure = error as? SetupError
        }
        let connections = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
            .codeHostingConnections
        let projectText = try? String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        return Outcome(prompts: console.prompts, error: failure, connections: connections, projectText: projectText)
    }

    @Test("An empty registry with gh logged in lists the gh offer; Enter connects gh and the Project selects it")
    func emptyRegistryEnterConnectsGitHubCLI() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let output = RecordingOutput()

        let result = try await run(
            machine: Self.board, answers: [""] + Self.declareProject, gh: gh, output: output
        )

        #expect(result.error?.message == nil)
        #expect(output.lines.contains("  1) Connect the gh CLI (acting as GitHub user octocat)"))
        #expect(output.lines.contains("  2) Connect a GitHub token (Keychain)…"))
        #expect(result.prompts.first == "Choose [1-2] (Enter for 1): ")
        #expect(result.connections == [CodeHostingConnection(name: "gh", kind: .githubCLI(executable: nil))])
        #expect(result.projectText?.contains("[code_hosting]\nconnection = \"gh\"") == true)
    }

    @Test("With a Keychain github in the registry, Enter picks the offered gh and 1 picks github, connecting nothing")
    func enterPicksTheOfferAndOnePicksGitHub() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let machine = Self.board + Self.keychainGitHub

        let entered = try await run(machine: machine, answers: ["", "n"], gh: gh)
        let one = try await run(machine: machine, answers: ["1", "n"], gh: gh)

        #expect(entered.prompts.first == "Choose [1-3] (Enter for 2): ")
        #expect(entered.connections.map(\.name) == ["github", "gh"])
        #expect(one.connections.map(\.name) == ["github"])
        #expect(one.prompts.first == "Choose [1-3] (Enter for 2): ")
    }

    @Test("When the name gh is taken by a Keychain connection, the offer asks for a name, proposing gh")
    func takenNameAsksForAnotherName() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let machine = Self.board + """


            [code_hosting.github.connections.gh]
            type = "keychain"
            credential = "keychain:github"
            """

        let result = try await run(machine: machine, answers: ["2", "", "mac", "n"], gh: gh)

        #expect(result.connections.map(\.name) == ["gh", "mac"])
        #expect(result.connections.last?.kind == .githubCLI(executable: nil))
        #expect(result.prompts.contains("Local name for this connection: "))
    }

    @Test("A logged-out gh prints one hint and offers no gh line")
    func loggedOutPrintsAHint() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let output = RecordingOutput()

        let result = try await run(
            machine: Self.board + Self.keychainGitHub, answers: ["1", "n"], gh: gh, output: output
        )

        let hint = "gh is installed but not logged in; run `gh auth login` to offer it here"
        #expect(output.lines.filter { $0 == hint }.count == 1)
        #expect(!output.lines.contains { $0.contains("Connect the gh CLI") })
        #expect(result.prompts.first == "Choose [1-2]: ")
        #expect(result.connections.map(\.name) == ["github"])
    }

    @Test("A missing gh offers nothing and prints no hint; an empty registry goes straight to the Keychain flow")
    func missingGitHubCLIOffersNothing() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let output = RecordingOutput()

        let result = try await run(
            machine: Self.board, answers: ["", "ghp_first", "n"], gh: gh, found: false, output: output
        )

        #expect(result.error?.message == nil)
        #expect(result.prompts.first == "Local name for this connection [github]: ")
        #expect(!output.lines.contains { $0.contains("gh") && $0.contains("offer it here") })
        #expect(result.connections.map(\.name) == ["github"])
        #expect(gh.calls.isEmpty)
    }

    @Test("An existing gh entry is pre-selected on Enter, and gh is not asked to be offered")
    func existingEntryIsPreselected() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let machine = Self.board + Self.keychainGitHub + Self.gitHubCLIEntry

        let result = try await run(machine: machine, answers: ["", "n"], gh: gh)

        #expect(result.prompts.first == "Choose [1-3] (Enter for 2): ")
        #expect(result.connections.map(\.name) == ["github", "gh"])
        #expect(gh.calls.isEmpty)
    }

    @Test("--skip-github-check never runs gh and offers no gh line")
    func skipGitHubCheckNeverRunsGitHubCLI() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }

        let result = try await run(
            machine: Self.board + Self.keychainGitHub, answers: ["1", "n"], gh: gh, skipGitHubCheck: true
        )

        #expect(gh.calls.isEmpty)
        #expect(result.prompts.first == "Choose [1-1]: ")
        #expect(result.connections.map(\.name) == ["github"])
    }

    @Test("--init with an empty registry points at connect-code-hosting --gh-cli")
    func initHintMentionsGitHubCLI() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.board)
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearTeam: "ENG", specSource: "~/dev/demo-spec",
                repo: ["backend,backend,~/dev/demo-backend,swift test"], installation: "acme",
                omitCodeHostingConnection: true
            ),
            directory: directory, board: await makeBoard(project: nil), gitHub: gh.validation(),
            seedGitHubConnection: false
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.message.contains("yh config connect-code-hosting gh --gh-cli") == true)
    }
}
