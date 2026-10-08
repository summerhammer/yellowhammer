import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// `yh doctor` Check 5 and `yh setup` with a Project that selects the `gh` CLI Code Hosting Connection.
@Suite("gh CLI Code Hosting Connection: doctor and setup")
struct GitHubCLIDoctorSetupTests {
    private static let machine = ConfigurationDirectory.machineFile + """


        [code_hosting.github.connections.gh]
        type = "gh"
        """

    private static func writeProject(
        _ directory: borrowing ConfigurationDirectory, id: String, connection: String = "gh"
    ) throws {
        try directory.writeProjectFile(id: id, """
            id = "\(id)"
            name = "\(id)"
            board = { linear = { connection = "acme", project = "\(id)" } }
            code_hosting = { connection = "\(connection)" }
            spec_source = "~/Developer/\(id)-spec"

            [[repos]]
            name = "backend"
            path = "~/dev/\(id)-backend"
            role = "backend"
            check = "swift test"
            """)
    }

    private func findings(
        _ directory: borrowing ConfigurationDirectory, gh: StubGitHubCLI, found: Bool = true
    ) async -> [DoctorFinding] {
        await makeDoctor(directory: directory, gitHub: gh.validation(found: found), checks: [.github])
            .run().filter { $0.check == .github }
    }

    // MARK: Doctor

    @Test("A gh connection serving a Project passes with the live login, then checks each working Repo")
    func doctorPasses() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        try Self.writeProject(directory, id: "alpha")

        let findings = await findings(directory, gh: gh).filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.pass, .pass])
        #expect(findings[0].message.hasPrefix(
            "Code Hosting Connection gh (type \"gh\"; login \"octocat\"; Projects alpha): "
        ))
        #expect(findings[0].message.contains("The gh CLI (\(gh.path)) acts as GitHub user octocat."))
        #expect(findings[1].subject == "repo backend")
        #expect(findings[1].message.contains("Repo backend (acme/alpha-backend): gh's active account can push."))
        #expect(findings.allSatisfy { !$0.message.contains("token") || $0.message.contains("gh's") })
    }

    @Test("A logged-out gh fails the connection, names gh auth login and skips the Repos")
    func doctorLoggedOut() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        try Self.writeProject(directory, id: "alpha")

        let findings = await findings(directory, gh: gh).filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.failure])
        #expect(findings[0].message.contains("gh auth login"))
        #expect(findings[0].codeHosting?.projects == [try #require(ProjectID(rawValue: "alpha"))])
    }

    @Test("A gh that is not found fails the connection with the shared message")
    func doctorMissing() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        try Self.writeProject(directory, id: "alpha")

        let findings = await findings(directory, gh: gh, found: false).filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.failure])
        #expect(findings[0].message.contains(GitHubCLIExecutable.notFoundMessage))
    }

    @Test("A gh that fails with stderr only is a warning, not a failure")
    func doctorUnreachable() async throws {
        let gh = try StubGitHubCLI(mode: .failing)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        try Self.writeProject(directory, id: "alpha")

        let findings = await findings(directory, gh: gh).filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.warning])
        #expect(findings[0].message.contains("gh could not reach GitHub"))
    }

    @Test("A Repo gh's account cannot push to fails on its own row")
    func doctorNoPush() async throws {
        let gh = try StubGitHubCLI(canPush: false)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        try Self.writeProject(directory, id: "alpha")

        let findings = await findings(directory, gh: gh).filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.pass, .failure])
        #expect(findings[1].message.contains("gh's active account lacks push permission"))
    }

    @Test("An unreferenced gh connection is information, with the login when gh answers")
    func doctorUnreferenced() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)

        let found = await findings(directory, gh: gh).filter { $0.codeHosting?.name == "gh" }
        let missing = await findings(directory, gh: gh, found: false).filter { $0.codeHosting?.name == "gh" }

        #expect(found.map(\.severity) == [.info])
        #expect(found[0].message.contains("login \"octocat\""))
        #expect(found[0].message.contains("No Project uses it yet."))
        #expect(missing.map(\.severity) == [.info])
        #expect(missing[0].message.contains(GitHubCLIExecutable.notFoundMessage))
    }

    // MARK: Setup

    private func arguments() -> [String] {
        makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG", specSource: "~/dev/demo-spec",
            repo: ["backend,backend,~/dev/demo-backend,swift test"], installation: "acme",
            codeHostingConnection: "gh"
        )
    }

    private func projectFile(_ directory: borrowing ConfigurationDirectory) -> URL {
        directory.url.appending(components: "projects", "demo.toml")
    }

    @Test("--init --project selecting gh writes the Project once gh answers and can push, storing no token")
    func setupAcceptsGitHubCLI() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        let credentials = RecordingCredentialStore(seed: ["keychain:linear": "x", "keychain:linear-acme": "x"])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: arguments(), directory: directory, board: await makeBoard(project: nil),
            credentials: credentials, output: output, gitHub: gh.validation()
        )

        try await setup.run()

        let text = try String(contentsOf: projectFile(directory), encoding: .utf8)
        #expect(text.contains("[code_hosting]\nconnection = \"gh\""))
        #expect(credentials.storedSecrets.isEmpty)
        #expect(output.lines.contains { $0.contains("acts as GitHub user octocat") })
        #expect(output.lines.contains { $0.contains("gh's active account can push") })
    }

    @Test("--init --project selecting a logged-out gh is refused through the GitHub failure path")
    func setupRefusesLoggedOut() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(
            arguments: arguments(), directory: directory, board: board, gitHub: gh.validation()
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.message.contains("gh auth login") == true)
        #expect(error?.isGitHubFailure == true)
        #expect(await board.creates == 0)
        #expect(!FileManager.default.fileExists(atPath: projectFile(directory).path))
    }

    @Test("--init --project selecting gh lists every Repo gh cannot push to")
    func setupListsFailingRepos() async throws {
        let gh = try StubGitHubCLI(canPush: false)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machine)
        let board = await makeBoard(project: nil)
        let setup = try makeSetup(
            arguments: arguments(), directory: directory, board: board, gitHub: gh.validation()
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        let message = try #require(error?.message)
        #expect(message.hasPrefix("The gh CLI cannot publish every Repo:"))
        #expect(message.contains("Repo backend (acme/demo-backend): gh's active account lacks push permission."))
        #expect(await board.creates == 0)
    }
}
