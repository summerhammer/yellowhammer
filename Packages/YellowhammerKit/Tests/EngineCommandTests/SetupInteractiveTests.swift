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
            "", // Linear credential -> default
            "", // GitHub credential -> default
            "", // CLI Adapters -> none
            "", // catch-all route -> none
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
            "", "", "", "", // Linear/GitHub credential, CLI Adapters, catch-all route
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
        #expect(projectText.contains(#"linear_project = "fake-1""#)) // glossary:ignore GL001

        // A second interactive run, declining to declare the Project again, creates nothing further.
        let secondConsole = ScriptedConsole(answers: ["n"])
        let secondSetup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: secondConsole
        )
        try await secondSetup.run()
        #expect(await board.creates >= 1)
    }

    @Test("No Installation token pair yet: interactive mode throws, naming the fix, and never prompts")
    func interactiveMissingInstallationThrows() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let arguments = makeArguments(initialize: false, operatorID: "user-op")
        let console = ScriptedConsole(answers: ["n"])
        let credentials = RecordingCredentialStore()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(console.prompts.isEmpty)
    }

    @Test("EOF at the Operator prompt throws and writes no Project file")
    func eofAtOperatorPromptThrows() async throws {
        let directory = ConfigurationDirectory()
        let board = await makeBoard(members: [operatorMember, secondCandidateMember])
        let arguments = makeArguments(initialize: false)
        let console = ScriptedConsole(answers: ["", "", "", ""])
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board, console: console)

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(!FileManager.default.fileExists(
            atPath: directory.url.appending(components: "projects", "demo.toml").path(percentEncoded: false)
        ))
    }
}
