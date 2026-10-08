import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

@Suite("yh setup --print-choices")
struct SetupPrintChoicesTests {
    @Test("Prints one decodable JSON line, filters candidates, and writes nothing") // glossary:ignore GL001
    func printsChoicesWithoutWritingConfig() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let machineFile = directory.url.appending(component: "config.toml")
        let machineBefore = try Data(contentsOf: machineFile)
        let board = await makeBoard(
            members: [operatorMember, secondCandidateMember, deactivatedMember, appMember, selfMember],
            teams: [engineeringTeam]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory, board: board,
            output: output
        )

        try await setup.run()

        #expect(output.lines.count == 1)
        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(Set(choices.operatorCandidates.map(\.id)) == ["user-op", "user-second"])
        #expect(choices.configuredOperator == nil)
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(choices.cliAdapters == ["claude", "codex", "agy"])
        #expect(try Data(contentsOf: machineFile) == machineBefore)
        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(component: "projects").path(percentEncoded: false)
        ))
    }

    @Test("Completed and cancelled Linear projects are dropped, the board's order kept") // glossary:ignore GL001
    func linearProjectsFilteredInBoardOrder() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let team = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")
        func project(_ id: String, completed: Bool = false, canceled: Bool = false) -> BoardLinearProject {
            BoardLinearProject(
                id: BoardObjectID(rawValue: id), name: "Name \(id)", teams: [team],
                isCompleted: completed, isCanceled: canceled
            )
        }
        await board.setLinearProjects([
            project("b"), project("done", completed: true), project("a"), project("gone", canceled: true)
        ])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory, board: board,
            output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.linearProjects == [
            SetupChoices.LinearProject(id: "b", name: "Name b", teamNames: ["Engineering"]),
            SetupChoices.LinearProject(id: "a", name: "Name a", teamNames: ["Engineering"])
        ])
    }

    @Test("A failing Linear projects read warns and still prints the teams and candidates") // glossary:ignore GL001
    func failedProjectsReadKeepsTeams() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(teams: [engineeringTeam])
        await board.failLinearProjects(with: .unreadableResponse("boom"))
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory, board: board,
            output: output
        )

        try await setup.run()

        #expect(output.lines.count == 2)
        #expect(output.lines.first?.hasPrefix("warning: could not list the Linear projects") == true)
        let data = try #require(output.lines.last?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.linearProjects.isEmpty)
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(!choices.operatorCandidates.isEmpty)
    }

    @Test("The configured Operator is reported only while still a candidate") // glossary:ignore GL001
    func configuredOperatorReportedOnlyWhileCandidate() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"
            operator = "user-op"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        let board = await makeBoard(members: [operatorMember], teams: [engineeringTeam])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory,
            board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.configuredOperator == "user-op")
    }

    @Test("A configured Operator who is no longer a candidate is not reported") // glossary:ignore GL001
    func configuredOperatorNoLongerCandidateIsNotReported() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"
            operator = "user-dead"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        let board = await makeBoard(members: [operatorMember, deactivatedMember], teams: [engineeringTeam])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory,
            board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.configuredOperator == nil)
    }

    @Test("--board-connection naming an entry without a token pair refuses, naming the fix") // glossary:ignore GL001
    func missingInstallationThrows() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory,
            board: await makeBoard(),
            credentials: RecordingCredentialStore()
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description.contains("yh setup --install-linear --board-connection acme") == true)
    }

    @Test("--board-connection naming no entry refuses with the unknown-installation message") // glossary:ignore GL001
    func unknownInstallationRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "nope"], directory: directory, board: await makeBoard()
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description == Setup.unknownInstallationMessage("nope", connected: ["acme"]))
    }

    @Test("No --board-connection lists every entry in file order and makes no Linear call") // glossary:ignore GL001
    func noFlagListsRegistryOnly() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.beta]
            credential = "keychain:linear-beta"
            workspace = "workspace-2"
            yellowhammer_identity = "app-user-2"
            operator = "user-op"

            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        let bound = Mutex<[String]>([])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices"], directory: directory, board: await makeBoard(), output: output,
            onBind: { installation in bound.withLock { $0.append(installation.name) } }
        )

        try await setup.run()

        #expect(bound.withLock { $0 }.isEmpty)
        #expect(output.lines.count == 1)
        let choices = try JSONDecoder().decode(SetupChoices.self, from: Data(try #require(output.lines.first).utf8))
        #expect(choices.installations == [
            SetupChoices.Installation(name: "beta", workspace: "workspace-2", operatorIdentity: "user-op"),
            SetupChoices.Installation(name: "acme", workspace: "workspace-1", operatorIdentity: nil)
        ])
        #expect(choices.operatorCandidates.isEmpty)
        #expect(choices.teams.isEmpty)
        #expect(choices.linearProjects.isEmpty)
        #expect(choices.configuredOperator == nil)
    }

    @Test("No --board-connection and no entries, or no config.toml, prints an empty registry") // glossary:ignore GL001
    func noFlagWithoutEntriesPrintsEmptyRegistry() async throws {
        for machineFile in [nil, ConfigurationDirectory.githubOnly] as [String?] {
            let directory = ConfigurationDirectory()
            if let machineFile { try directory.writeMachineFile(machineFile) }
            let output = RecordingOutput()
            let setup = try makeSetup(
                arguments: ["--print-choices"], directory: directory, board: await makeBoard(), output: output
            )

            try await setup.run()

            let line = try #require(output.lines.first)
            #expect(output.lines.count == 1)
            #expect(line.contains("\"installations\":[]"))
        }
    }

    @Test("--board-connection reads one entry and still lists the whole registry") // glossary:ignore GL001
    func scopedReadIncludesFullRegistry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [board.linear.connections.beta]
            credential = "keychain:linear-beta"
            workspace = "workspace-2"
            yellowhammer_identity = "app-user-2"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme"], directory: directory,
            board: await makeBoard(teams: [engineeringTeam]), output: output
        )

        try await setup.run()

        let choices = try JSONDecoder().decode(SetupChoices.self, from: Data(try #require(output.lines.last).utf8))
        #expect(choices.installations.map(\.name) == ["acme", "beta"])
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
    }

    @Test("--print-choices is mutually exclusive with --init") // glossary:ignore GL001
    func printChoicesWithInitRefused() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--print-choices", "--init"])
        }
    }

    @Test("--print-choices is mutually exclusive with --config") // glossary:ignore GL001
    func printChoicesWithConfigRefused() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--print-choices", "--config", "/tmp/prepared"])
        }
    }

    @Test("--print-choices is mutually exclusive with --project") // glossary:ignore GL001
    func printChoicesWithProjectRefused() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse([
                "--print-choices", "--project", "demo", "--linear-project", "proj-1" // glossary:ignore GL001
            ])
        }
    }

    @Test("--print-choices is mutually exclusive with --install-jobs") // glossary:ignore GL001
    func printChoicesWithInstallJobsRefused() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--print-choices", "--install-jobs"])
        }
    }

    @Test("--print-choices allows the Linear options") // glossary:ignore GL001
    func printChoicesAllowsLinearOptions() throws {
        let command = try SetupCommand.parse([
            "--print-choices",
            "--board-connection", "main"
        ])
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
    }

    @Test("--print-choices allows --linear-project when --board-connection is present") // glossary:ignore GL001
    func printChoicesAllowsLinearProjectWithInstallation() throws {
        let command = try SetupCommand.parse([
            "--print-choices",
            "--board-connection", "main",
            "--linear-project", "proj-1"
        ])
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
        #expect(options.installation == "main")
        #expect(options.linearProjectID == "proj-1")
    }

    @Test("--print-choices with --linear-project without --board-connection is refused") // glossary:ignore GL001
    func printChoicesRefusesLinearProjectWithoutInstallation() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--print-choices", "--linear-project", "proj-1"])
        }
    }

    @Test("--print-choices with --linear-project reports found project") // glossary:ignore GL001
    func printChoicesReportsFoundLinearProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let projectScope = BoardProjectScope(
            id: BoardObjectID(rawValue: "proj-1"),
            name: "Billing Revamp",
            teams: [engineeringTeam]
        )
        let board = await makeBoard(
            project: projectScope,
            members: [operatorMember],
            teams: [engineeringTeam]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme", "--linear-project", "proj-1"],
            directory: directory, board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.linearProjectCheck == SetupChoices.LinearProjectCheck(
            status: .found, id: "proj-1", name: "Billing Revamp", teamNames: ["Engineering"]
        ))
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(!choices.operatorCandidates.isEmpty)
    }

    @Test("--print-choices with --linear-project reports notFound when missing") // glossary:ignore GL001
    func printChoicesReportsNotFoundLinearProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(
            project: nil,
            members: [operatorMember],
            teams: [engineeringTeam]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme", "--linear-project", "proj-missing"],
            directory: directory, board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.linearProjectCheck == SetupChoices.LinearProjectCheck(status: .notFound))
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(!choices.operatorCandidates.isEmpty)
    }

    @Test("--print-choices with --linear-project reports noTeamAccess when not a member") // glossary:ignore GL001
    func printChoicesReportsNoTeamAccessLinearProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let projectScope = BoardProjectScope(
            id: BoardObjectID(rawValue: "proj-1"),
            name: "Secret Project",
            teams: [engineeringTeam]
        )
        let board = await makeBoard(
            project: projectScope,
            members: [operatorMember],
            teams: [engineeringTeam]
        )
        await board.excludeMembership(of: engineeringTeam.id)
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "acme", "--linear-project", "proj-1"],
            directory: directory, board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.linearProjectCheck == SetupChoices.LinearProjectCheck(
            status: .noTeamAccess, id: "proj-1", name: "Secret Project", teamNames: ["Engineering"]
        ))
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(!choices.operatorCandidates.isEmpty)
    }
}
