import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

private let productTeam = BoardTeam(id: BoardObjectID(rawValue: "team-2"), key: "PRD", name: "Product")

@Suite("yh setup, interactive")
struct SetupInteractiveTests {
    @Test("An interactive clean run writes a valid configuration; nothing about the Operator is preselected")
    func interactiveCleanRun() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(members: [operatorMember, secondCandidateMember])
        let arguments = makeArguments(initialize: false)
        let console = ScriptedConsole(answers: [
            "", // GitHub credential -> default
            "", // CLI Adapters -> none
            "", // catch-all route -> none
            "", // Linear is not installed: "Are you a workspace admin?" -> install here
            "", // Local name -> proposed
            "", // Operator: empty re-asks
            "99", // Operator: out of range re-asks
            "2", // Operator: candidate #2
            "n" // Declare a Project now?
        ])
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, console: console)

        try await setup.run()

        let configuration = try Configuration.load(directory: directory.url)
        #expect(configuration.invalidProjects.isEmpty)
        let machineText = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(machineText.contains(#"operator = "user-second""#))
    }

    @Test("An interactive run creates the Linear project via a team chosen by number, exactly once")
    func interactiveTeamChoiceCreatesProjectOnce() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(project: nil, teams: [engineeringTeam, productTeam])
        let arguments = makeArguments(
            initialize: false, operatorID: "user-op"
        )
        let console = ScriptedConsole(answers: [
            "", "", "", // GitHub credential, CLI Adapters, catch-all route
            "", // Linear is not installed: "Are you a workspace admin?" -> install here
            "", // Local name -> proposed
            "y", // Declare a Project now?
            "demo", // Project id
            "", // Project name -> default
            "", // Linear project id -> empty creates one
            "2", // Team #2 (Product)
            "~/dev/demo-spec", // Spec Source path
            "backend", "~/dev/demo-backend", "backend", "swift test", // repo name/path/role/check
            "n", // Add another repo?
            "n" // Declare another Project?
        ])
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, console: console)

        try await setup.run()

        let projectText = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        let project = try ProjectConfiguration.parse(projectText, file: "demo.toml")
        #expect(project.linearProject == "fake-1")
        #expect(project.linearInstallationName == "acme")

        // A second interactive run, declining to declare the Project again, creates nothing further.
        let secondConsole = ScriptedConsole(answers: ["n"])
        let secondSetup = try makeSetup(
            arguments: arguments + ["--board-connection", "acme"], directory: directory, board: board,
            console: secondConsole
        )
        try await secondSetup.run()
        #expect(await board.creates >= 1)
    }

    @Test("No Installation token pair yet: interactive mode attempts the install, all ports busy, cancel throws")
    func interactiveMissingInstallationAttemptsInstallThenThrows() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let console = ScriptedConsole(answers: ["c"])
        let credentials = RecordingCredentialStore.withGitHub()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            linearInstallSeams: busyLinearInstallSeams()
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        // The admin question (roadmap P17.9) asks first and consumes "c" (not "r": local path); every
        // port bound busy by `busyLinearInstallSeams()` then offers retry/cancel exactly once, with
        // no more scripted answers left, so it throws too.
        #expect(console.prompts.count == 2)
    }

    @Test("EOF at the Operator prompt throws and writes no Project file")
    func eofAtOperatorPromptThrows() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(members: [operatorMember, secondCandidateMember])
        let arguments = makeArguments(initialize: false)
        let console = ScriptedConsole(answers: ["", "", "", ""])
        // GitHub, CLI, route, install-here; then EOF at the Operator
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, console: console)

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        ))
    }
}
