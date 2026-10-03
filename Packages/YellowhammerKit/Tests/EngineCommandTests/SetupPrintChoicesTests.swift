import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
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
        let setup = try makeSetup(arguments: ["--print-choices"], directory: directory, board: board, output: output)

        try await setup.run()

        #expect(output.lines.count == 1)
        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(Set(choices.operatorCandidates.map(\.id)) == ["user-op", "user-second"])
        #expect(choices.configuredOperator == nil)
        #expect(choices.teams == [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")])
        #expect(choices.cliAdapters == ["claude", "codex"])
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
        let setup = try makeSetup(arguments: ["--print-choices"], directory: directory, board: board, output: output)

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
        let setup = try makeSetup(arguments: ["--print-choices"], directory: directory, board: board, output: output)

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
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"
            operator = "user-op"

            [github]
            credential = "keychain:github"
            """)
        let board = await makeBoard(members: [operatorMember], teams: [engineeringTeam])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices"], directory: directory, board: board, output: output
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
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"
            operator = "user-dead"

            [github]
            credential = "keychain:github"
            """)
        let board = await makeBoard(members: [operatorMember, deactivatedMember], teams: [engineeringTeam])
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices"], directory: directory, board: board, output: output
        )

        try await setup.run()

        let data = try #require(output.lines.first?.data(using: .utf8))
        let choices = try JSONDecoder().decode(SetupChoices.self, from: data)
        #expect(choices.configuredOperator == nil)
    }

    @Test("No Installation token pair yet: --print-choices throws, naming the fix") // glossary:ignore GL001
    func missingInstallationThrows() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let credentials = RecordingCredentialStore()
        let setup = try makeSetup(
            arguments: ["--print-choices"], directory: directory, board: board, credentials: credentials
        )

        await #expect(throws: SetupError.self) { try await setup.run() }
    }

    @Test("No App Installation at all: --print-choices says Yellowhammer is not installed yet") // glossary:ignore GL001
    func noInstallationThrowsNotInstalled() async throws {
        for machineFile in [nil, "[github]\ncredential = \"keychain:github\"\n"] as [String?] {
            let directory = ConfigurationDirectory()
            if let machineFile { try directory.writeMachineFile(machineFile) }
            let setup = try makeSetup(
                arguments: ["--print-choices"], directory: directory, board: await makeBoard()
            )
            do {
                try await setup.run()
                Issue.record("expected a SetupError")
            } catch let error as SetupError {
                #expect(error.description.contains("not installed in a Linear workspace yet"))
                #expect(error.description.contains("yh setup --install-linear"))
            }
        }
    }

    @Test("Two App Installations: --print-choices reads exactly one and names the count") // glossary:ignore GL001
    func twoInstallationsThrowCount() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"

            [board.linear.installations.beta]
            credential = "keychain:linear-beta"
            workspace = "workspace-2"
            app_user = "app-user-2"

            [github]
            credential = "keychain:github"
            """)
        let setup = try makeSetup(arguments: ["--print-choices"], directory: directory, board: await makeBoard())
        do {
            try await setup.run()
            Issue.record("expected a SetupError")
        } catch let error as SetupError {
            #expect(error.description.contains("config.toml declares 2 Linear App Installations"))
            #expect(error.description.contains("reads one"))
        }
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

    @Test("--print-choices allows the Linear credential options") // glossary:ignore GL001
    func printChoicesAllowsLinearOptions() throws {
        let command = try SetupCommand.parse([
            "--print-choices",
            "--linear-credential", "keychain:linear", "--github-credential", "keychain:github"
        ])
        let options = try SetupOptions(command: command)

        #expect(options.mode == .printChoices)
    }
}
