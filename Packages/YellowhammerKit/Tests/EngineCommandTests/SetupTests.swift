import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Engine
import Foundation
import Testing

@Suite("yh setup")
struct SetupTests {
    @Test("--init on a clean directory writes both files, with zero invalid Projects")
    func initWritesBothFiles() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        )
        let arguments = makeArguments(
            cli: ["claude"], route: "claude/sonnet/medium",
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let output = RecordingOutput()
        let console = ScriptedConsole()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, output: output
        )

        try await setup.run()

        let configuration = try Configuration.load(directory: directory.url)
        #expect(configuration.invalidProjects.isEmpty)
        #expect(configuration.projects.map(\.id.rawValue) == ["demo"])
        let projectText = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        #expect(projectText.contains("unanswered_nights_max = 3"))
        let machineText = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(machineText.contains(#"operator = "user-op""#))
        #expect(output.lines.contains("Setup complete."))
        #expect(console.prompts.isEmpty, "--init must never touch the console")
    }

    @Test("Re-running the identical setup changes nothing and creates nothing the second time")
    func rerunIsIdempotent() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        )
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let setup1 = try makeSetup(arguments: arguments, directory: directory, board: board)
        try await setup1.run()
        let machineTextAfterFirst = try String(
            contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8
        )
        let projectTextAfterFirst = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        let createsAfterFirst = await board.creates

        let setup2 = try makeSetup(arguments: arguments, directory: directory, board: board)
        try await setup2.run()

        let machineTextAfterSecond = try String(
            contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8
        )
        let projectTextAfterSecond = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        #expect(machineTextAfterFirst == machineTextAfterSecond)
        #expect(projectTextAfterFirst == projectTextAfterSecond)
        #expect(await board.creates == createsAfterFirst)
    }

    @Test("--linear-team creates the Linear project exactly once and writes its id as linear_project")
    func linearTeamCreatesProjectOnce() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let setup1 = try makeSetup(arguments: arguments, directory: directory, board: board)

        try await setup1.run()

        let projectText = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        #expect(projectText.contains(#"linear_project = "fake-1""#)) // glossary:ignore GL001
        let createsAfterFirst = await board.creates

        let setup2 = try makeSetup(arguments: arguments, directory: directory, board: board)
        try await setup2.run()
        #expect(await board.creates == createsAfterFirst)
    }

    @Test("--linear-team on a team the app can see but is not a member of refuses, with no create")
    func linearTeamVisibleButNotAMemberRefuses() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil)
        await board.excludeMembership(of: engineeringTeam.id)
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearTeam: "ENG",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board)

        await #expect(throws: (any Error).self) { try await setup.run() }

        #expect(await board.creates == 0)
        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        ))
    }

    @Test("A permission refusal is listed once more, consolidated, as the last block of setup's output")
    func unfinishedProvisioningIsConsolidatedAtTheEnd() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        )
        await board.script(.refuse(.forbidden("not allowed")), for: BoardProvisioner.blockedState)
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, output: output)

        try await setup.run()

        let consolidatedIndex = try #require(output.lines.firstIndex(of: "Unfinished provisioning steps:"))
        let perProjectIndex = try #require(output.lines.firstIndex(of: "Project demo:")) // glossary:ignore GL001
        #expect(consolidatedIndex > perProjectIndex)
        #expect(output.lines[(consolidatedIndex + 1)...].contains { $0.contains("permission refused") })
        #expect(output.lines[(consolidatedIndex + 1)...].contains { $0.contains("Blocked") })
        // The guideline is the last content line before "Setup complete.": nothing else follows it.
        #expect(output.lines.last == "Setup complete.")
        #expect(output.lines[output.lines.count - 2].contains("category started"))
    }

    @Test("An absent operator throws, listing the candidates, with no Project file and no provisioning")
    func absentOperatorThrows() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam]),
            members: [operatorMember]
        )
        let arguments = makeArguments(project: "demo", linearProject: "proj-1")
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, output: output)

        await #expect(throws: (any Error).self) { try await setup.run() }

        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        ))
        #expect(await board.creates == 0)
    }

    @Test(
        "An --operator naming a deactivated member, an app, or self is refused, with no side effects",
        arguments: [deactivatedMember, appMember, selfMember]
    )
    func excludedOperatorIsRefused(excludedMember: BoardMember) async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam]),
            members: [operatorMember, excludedMember]
        )
        let arguments = makeArguments(
            operatorID: excludedMember.id.rawValue, project: "demo", linearProject: "proj-1"
        )
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board)

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        ))
        #expect(await board.creates == 0)
    }

    @Test("A missing secret throws the guidance; --linear-client-secret-stdin stores it")
    func missingSecretThrowsGuidance() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op")
        let credentials = RecordingCredentialStore()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        let stdinArguments = makeArguments(operatorID: "user-op", linearClientSecretStdin: true)
        let setupWithStdin = try makeSetup(
            arguments: stdinArguments, directory: directory, board: board, credentials: credentials,
            readStandardInputLine: { "a-secret-from-stdin" }
        )
        try await setupWithStdin.run()
        #expect(credentials.secret(for: CredentialReference("keychain:linear")!) == "a-secret-from-stdin")
    }

    @Test("An existing hand-written config.toml keeps its comment after the operator is set")
    func handWrittenConfigKeepsComments() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            # do not touch this line
            [linear]
            credential = "keychain:linear"
            client_id = "yellowhammer-client-id"

            [github]
            credential = "keychain:github"
            """)
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op")
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board)

        try await setup.run()

        let text = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(text.contains("# do not touch this line"))
        #expect(text.contains(#"operator = "user-op""#))
    }

    @Test("Notifications off still completes setup, and the off line is printed exactly once")
    func notificationsOffStillCompletes() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op")
        let output = RecordingOutput()
        let notifications = NotificationRegistrationStub(.off(reason: "denied"))
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, output: output, notifications: notifications
        )

        try await setup.run()

        #expect(notifications.callCount == 1)
        let offLines = output.lines.filter { $0.hasPrefix("Local notifications: off") }
        #expect(offLines.count == 1)
        #expect(offLines.first?.contains("denied") == true)
        #expect(output.lines.contains("Setup complete."))
    }

    @Test("Routing warnings are printed for a no-fallback entry and a single-CLI entry")
    func routingWarningsArePrinted() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard()
        let arguments = makeArguments(
            cli: ["claude", "codex"], route: "claude/sonnet/medium", fallback: ["claude/opus/high"],
            operatorID: "user-op"
        )
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, output: output)

        try await setup.run()

        #expect(output.lines.contains { $0.hasPrefix("warning:") && $0.contains("single CLI") })
    }

    @Test("An invalid Project already in the directory is reported; a valid sibling is still provisioned")
    func invalidProjectSiblingStillProvisions() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "broken", "id = \"broken\"\n")
        try directory.writeValidProjectFile(id: "healthy")
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "healthy", teams: [engineeringTeam])
        )
        let arguments = makeArguments(operatorID: "user-op")
        let output = RecordingOutput()
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, output: output)

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(output.lines.contains { $0.contains("broken") })
        #expect(output.lines.contains { $0.contains("Project healthy:") })
    }
}
