import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup --print-choices")
struct SetupPrintChoicesTests {
    @Test("Prints one decodable JSON line, filters candidates, and writes no config.toml") // glossary:ignore GL001
    func printsChoicesWithoutWritingConfig() async throws {
        let directory = ConfigurationDirectory()
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
        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(component: "config.toml").path(percentEncoded: false)
        ))
    }

    @Test("The configured Operator is reported only while still a candidate") // glossary:ignore GL001
    func configuredOperatorReportedOnlyWhileCandidate() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [linear]
            credential = "keychain:linear"
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
            [linear]
            credential = "keychain:linear"
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
        let board = await makeBoard()
        let credentials = RecordingCredentialStore()
        let setup = try makeSetup(
            arguments: ["--print-choices"], directory: directory, board: board, credentials: credentials
        )

        await #expect(throws: SetupError.self) { try await setup.run() }
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
