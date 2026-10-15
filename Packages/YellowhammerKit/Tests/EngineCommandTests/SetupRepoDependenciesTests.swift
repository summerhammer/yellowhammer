import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

// app/propose-repository-dependencies-at-setup: `--consumes` declares an edge, `--init` only proposes, and the
// interactive run asks about each proposal.

/// Two sibling Repos on disk: `app`, whose `Package.swift` references `contracts` by path, and `contracts`.
private final class SiblingRepos: @unchecked Sendable {
    let root: URL

    init(appPackage: String = #".package(path: "../contracts"),"#, contractsPackage: String? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yh-setup-deps-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in ["app", "contracts"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true
            )
        }
        try appPackage.write(to: root.appending(path: "app/Package.swift"), atomically: true, encoding: .utf8)
        if let contractsPackage {
            try contractsPackage.write(
                to: root.appending(path: "contracts/Package.swift"), atomically: true, encoding: .utf8
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ name: String) -> String { root.appending(path: name).path(percentEncoded: false) }

    var repoArguments: [String] {
        ["app,backend,\(path("app")),swift test", "contracts,backend,\(path("contracts")),none"]
    }
}

private func demoBoard() async -> FakeProvisioningBoard {
    await makeBoard(
        project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
    )
}

private func projectFile(_ directory: borrowing ConfigurationDirectory) throws -> ProjectConfiguration {
    let text = try String(contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8)
    return try ProjectConfiguration.parse(text, file: "demo.toml")
}

@Suite("yh setup: Repo Dependencies")
struct SetupRepoDependenciesTests {
    // MARK: - --consumes

    @Test("--consumes folds each edge into its consumer's declaration, in order")
    func consumesParses() throws {
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            repo: ["backend,backend,~/dev/backend,swift test", "contracts,backend,~/dev/contracts,none"],
            consumes: ["backend,contracts,tag", "backend,spec,mainline"]
        )
        let options = try SetupOptions(command: try SetupCommand.parse(arguments))

        #expect(options.repos[0].consumes == [
            RepoDependency(producer: "contracts", via: .tag), RepoDependency(producer: "spec", via: .mainline)
        ])
        #expect(options.repos[1].consumes.isEmpty)
        #expect(options.hasProjectDeclarationOptions)
    }

    @Test("A malformed --consumes is refused", arguments: [
        "backend,contracts",
        "backend,contracts,tag,extra",
        "backend,,tag",
        "backend,contracts,branch",
        "web,contracts,tag"
    ])
    func consumesRefusals(entry: String) {
        let arguments = makeArguments(
            project: "demo", linearProject: "proj-1",
            repo: ["backend,backend,~/dev/backend,swift test"], consumes: [entry]
        )
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--consumes naming a consumer no --repo declared says so")
    func undeclaredConsumerMessage() throws {
        let arguments = makeArguments(
            project: "demo", linearProject: "proj-1",
            repo: ["backend,backend,~/dev/backend,swift test"], consumes: ["web,contracts,tag"]
        )
        do {
            _ = try SetupCommand.parse(arguments)
            Issue.record("expected a refusal")
        } catch {
            #expect(
                SetupCommand.message(for: error).contains(
                    #"--consumes names consumer "web", which was not declared with --repo"#
                )
            )
        }
    }

    @Test("--consumes requires --project")
    func consumesRequiresProject() {
        let arguments = makeArguments(consumes: ["backend,contracts,tag"])
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--init with --consumes writes the edge under its consumer's [[repos]]")
    func initWritesDeclaredEdge() async throws {
        let directory = ConfigurationDirectory()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearProject: "proj-1", specSource: "~/dev/demo-spec",
                repo: ["backend,backend,~/dev/backend,swift test", "contracts,backend,~/dev/contracts,none"],
                consumes: ["backend,contracts,tag"]
            ),
            directory: directory, board: await demoBoard()
        )

        try await setup.run()

        let text = try String(contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8)
        #expect(text.contains(#"consumes = [{ repo = "contracts", via = "tag" }]"#))
        let project = try projectFile(directory)
        #expect(project.repos[0].consumes == [RepoDependency(producer: "contracts", via: .tag)])
        #expect(project.repos[1].consumes.isEmpty)
    }

    @Test("--init with --consumes forming a cycle is refused with the loader's message and writes no Project file")
    func initRefusesCycle() async throws {
        let directory = ConfigurationDirectory()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearProject: "proj-1", specSource: "~/dev/demo-spec",
                repo: ["backend,backend,~/dev/backend,swift test", "contracts,backend,~/dev/contracts,none"],
                consumes: ["backend,contracts,tag", "contracts,backend,mainline"]
            ),
            directory: directory, board: await demoBoard()
        )

        do {
            try await setup.run()
            Issue.record("expected a refusal")
        } catch let error as SetupError {
            #expect(error.message.hasPrefix("Project demo:"))
            #expect(error.message.contains("Repo Dependencies form a cycle: backend -> contracts -> backend"))
        }
        let path = directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - --init proposes, never writes

    @Test("--init prints what it found, writes no consumes, and never touches the console")
    func initPrintsProposals() async throws {
        let repos = try SiblingRepos()
        let directory = ConfigurationDirectory()
        let output = RecordingOutput()
        let console = ScriptedConsole()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearProject: "proj-1", specSource: "~/dev/demo-spec",
                repo: repos.repoArguments
            ),
            directory: directory, board: await demoBoard(), console: console, output: output
        )

        try await setup.run()

        #expect(output.lines.contains(
            "Proposed Repo Dependencies (not written; pass --consumes consumer,producer,via to declare one):"
        ))
        #expect(output.lines.contains(
            #"Proposed: app consumes contracts via mainline — Package.swift: .package(path: "../contracts")"#
        ))
        #expect(try projectFile(directory).repos.allSatisfy { $0.consumes.isEmpty })
        #expect(console.prompts.isEmpty)
    }

    @Test("--init says so when nothing is found, and names a file it could not read")
    func initNothingFound() async throws {
        let directory = ConfigurationDirectory()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearProject: "proj-1", specSource: "~/dev/demo-spec",
                repo: ["backend,backend,~/dev/backend-not-on-disk,swift test"]
            ),
            directory: directory, board: await demoBoard(), output: output
        )

        try await setup.run()

        #expect(output.lines.contains(
            "No Repo Dependencies found among this Project's Repos; "
                + "declare any by hand with consumes = [...] in the Project file."
        ))
    }

    @Test("A proposal already declared with --consumes is not proposed again")
    func declaredEdgeIsNotProposed() async throws {
        let repos = try SiblingRepos()
        let directory = ConfigurationDirectory()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(
                operatorID: "user-op", project: "demo", linearProject: "proj-1", specSource: "~/dev/demo-spec",
                repo: repos.repoArguments, consumes: ["app,contracts,mainline"]
            ),
            directory: directory, board: await demoBoard(), output: output
        )

        try await setup.run()

        #expect(!output.lines.contains { $0.hasPrefix("Proposed") })
        #expect(try projectFile(directory).repos[0].consumes == [RepoDependency(producer: "contracts", via: .mainline)])
    }
}

// MARK: - Interactive

@Suite("yh setup, interactive: Repo Dependencies")
struct SetupInteractiveRepoDependenciesTests {
    /// The answers up to and including the Repos, then `proposalAnswers`, then declining another Project.
    private func answers(_ repos: SiblingRepos, proposalAnswers: [String?]) -> [String?] {
        [
            "", "", "", // CLI Adapters, catch-all route, Code Hosting Connection name
            "", // Linear is not installed: install here
            "", // Local name -> proposed
            "y", // Declare a Project now?
            "demo", "", // Project id, name
            "", "1", // Linear project: create one, team #1
            "~/dev/demo-spec",
            "app", repos.path("app"), "backend", "swift test", "y", // first repo, add another
            "contracts", repos.path("contracts"), "backend", "none", "n" // second repo, no more
        ] + proposalAnswers + ["n"] // Declare another Project?
    }

    private func run(
        _ repos: SiblingRepos, proposalAnswers: [String?], directory: borrowing ConfigurationDirectory
    ) async throws -> (console: ScriptedConsole, output: RecordingOutput) {
        let board = await makeBoard(project: nil, teams: [engineeringTeam])
        let console = ScriptedConsole(answers: answers(repos, proposalAnswers: proposalAnswers))
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", omitCodeHostingConnection: true),
            directory: directory, board: board, console: console, output: output
        )
        try await setup.run()
        return (console, output)
    }

    @Test("y confirms the guessed via and the Project file carries the edge")
    func yesDeclaresTheEdge() async throws {
        let repos = try SiblingRepos()
        let directory = ConfigurationDirectory()

        let (console, _) = try await run(repos, proposalAnswers: ["y"], directory: directory)

        #expect(console.prompts.contains("Declare app consumes contracts via mainline? [y/N/m/t] "))
        #expect(try projectFile(directory).repos[0].consumes == [RepoDependency(producer: "contracts", via: .mainline)])
    }

    @Test("n declares nothing, and t overrides the guess with a tag")
    func noAndTag() async throws {
        let declined = ConfigurationDirectory()
        _ = try await run(try SiblingRepos(), proposalAnswers: ["n"], directory: declined)
        #expect(try projectFile(declined).repos.allSatisfy { $0.consumes.isEmpty })

        let tagged = ConfigurationDirectory()
        _ = try await run(try SiblingRepos(), proposalAnswers: ["t"], directory: tagged)
        #expect(try projectFile(tagged).repos[0].consumes == [RepoDependency(producer: "contracts", via: .tag)])
    }

    @Test("An edge the loader would refuse is refused with its reason and the same proposal asked again")
    func refusedEdgeIsAskedAgain() async throws {
        let repos = try SiblingRepos(contractsPackage: #".package(path: "../app"),"#)
        let directory = ConfigurationDirectory()

        let (console, output) = try await run(repos, proposalAnswers: ["y", "y", "n"], directory: directory)

        let refusal = "Refused: Repo Dependencies form a cycle: app -> contracts -> app"
        #expect(output.lines.contains(refusal))
        let second = "Declare contracts consumes app via mainline? [y/N/m/t] "
        #expect(console.prompts.filter { $0 == second }.count == 2)
        let project = try projectFile(directory)
        #expect(project.repos[0].consumes == [RepoDependency(producer: "contracts", via: .mainline)])
        #expect(project.repos[1].consumes.isEmpty)
    }

    @Test("A commit pin has no guessed via: y is refused as an answer, m chooses mainline")
    func commitPinNeedsAChoice() async throws {
        let repos = try SiblingRepos(appPackage: "")
        try """
            [submodule "contracts"]
            \turl = \(repos.path("contracts"))
            """.write(to: repos.root.appending(path: "app/.gitmodules"), atomically: true, encoding: .utf8)
        // A submodule url naming a local path matches by origin, so give `contracts` that origin.
        try FileManager.default.createDirectory(
            at: repos.root.appending(path: "contracts/.git"), withIntermediateDirectories: true
        )
        try "[remote \"origin\"]\n\turl = \(repos.path("contracts"))\n".write(
            to: repos.root.appending(path: "contracts/.git/config"), atomically: true, encoding: .utf8
        )
        let directory = ConfigurationDirectory()

        let (console, _) = try await run(repos, proposalAnswers: ["y", "m"], directory: directory)

        #expect(console.prompts.filter { $0 == "Declare app consumes contracts via ? [m/t/N] " }.count == 2)
        #expect(try projectFile(directory).repos[0].consumes == [RepoDependency(producer: "contracts", via: .mainline)])
    }
}
