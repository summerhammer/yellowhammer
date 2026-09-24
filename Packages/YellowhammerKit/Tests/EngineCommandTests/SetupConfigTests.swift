import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup --config")
struct SetupConfigTests {
    private func preparedBoard() async -> FakeProvisioningBoard {
        await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "demo"), name: "demo", teams: [engineeringTeam])
        )
    }

    @Test("--config into an empty directory installs every file and the result validates")
    func configInstallsIntoEmptyDirectory() async throws {
        let prepared = ConfigurationDirectory()
        try prepared.writeMachineFile()
        try prepared.writeValidProjectFile(id: "demo")
        let destination = ConfigurationDirectory()
        let board = await preparedBoard()
        let arguments = makeArguments(
            initialize: false, config: prepared.path, linearClientID: nil, operatorID: "user-op"
        )
        let output = RecordingOutput()
        let console = ScriptedConsole()
        let setup = try makeSetup(
            arguments: arguments, directory: destination, board: board, console: console, output: output
        )

        try await setup.run()

        let configuration = try Configuration.load(directory: destination.url)
        #expect(configuration.invalidProjects.isEmpty)
        #expect(configuration.projects.map(\.id.rawValue) == ["demo"])
        #expect(output.lines.contains { $0.hasPrefix("installed") && $0.contains("config.toml") })
        #expect(output.lines.contains { $0.hasPrefix("installed") && $0.contains("demo.toml") })
        #expect(console.prompts.isEmpty, "--config must never prompt")
    }

    @Test("A second identical --config run reports present and changes nothing")
    func configSecondRunReportsPresent() async throws {
        let prepared = ConfigurationDirectory()
        // The Operator is already configured and a candidate, so adopting it never rewrites the file —
        // otherwise the destination's config.toml would no longer match the source on the second run.
        try prepared.writeMachineFile("""
            [linear]
            credential = "keychain:linear"
            client_id = "yellowhammer-client-id"
            operator = "user-op"

            [github]
            credential = "keychain:github"
            """)
        try prepared.writeValidProjectFile(id: "demo")
        let destination = ConfigurationDirectory()
        let board = await preparedBoard()
        let arguments = makeArguments(
            initialize: false, config: prepared.path, linearClientID: nil, operatorID: "user-op"
        )
        try await makeSetup(arguments: arguments, directory: destination, board: board).run()

        let output = RecordingOutput()
        try await makeSetup(arguments: arguments, directory: destination, board: board, output: output).run()

        #expect(output.lines.contains { $0.hasPrefix("present") && $0.contains("config.toml") })
        #expect(output.lines.contains { $0.hasPrefix("present") && $0.contains("demo.toml") })
        #expect(!output.lines.contains { $0.hasPrefix("installed") })
    }

    @Test("A prepared config.toml without an operator is still present on the next run, after setup set it")
    func configWithoutOperatorSecondRunReportsPresent() async throws {
        let prepared = ConfigurationDirectory()
        try prepared.writeMachineFile()
        try prepared.writeValidProjectFile(id: "demo")
        let destination = ConfigurationDirectory()
        let board = await preparedBoard()
        let arguments = makeArguments(
            initialize: false, config: prepared.path, linearClientID: nil, operatorID: "user-op"
        )
        try await makeSetup(arguments: arguments, directory: destination, board: board).run()
        let machineFile = destination.url.appending(component: "config.toml")
        let afterFirstRun = try String(contentsOf: machineFile, encoding: .utf8)
        #expect(afterFirstRun.contains("operator = \"user-op\""))

        let output = RecordingOutput()
        try await makeSetup(arguments: arguments, directory: destination, board: board, output: output).run()

        #expect(output.lines.contains { $0.hasPrefix("present") && $0.contains("config.toml") })
        #expect(try String(contentsOf: machineFile, encoding: .utf8) == afterFirstRun)
    }

    @Test("A destination file that already differs refuses the whole setup, with nothing written")
    func configDifferingFileRefuses() async throws {
        let prepared = ConfigurationDirectory()
        try prepared.writeMachineFile()
        let destination = ConfigurationDirectory()
        try destination.writeMachineFile("""
            [linear]
            credential = "keychain:linear"
            client_id = "some-other-client-id"

            [github]
            credential = "keychain:github"
            """)
        let originalText = try String(contentsOf: destination.url.appending(component: "config.toml"), encoding: .utf8)
        let board = await preparedBoard()
        let arguments = makeArguments(
            initialize: false, config: prepared.path, linearClientID: nil, operatorID: "user-op"
        )
        let setup = try makeSetup(arguments: arguments, directory: destination, board: board)

        await #expect(throws: SetupError.self) { try await setup.run() }

        let afterText = try String(contentsOf: destination.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(afterText == originalText)
    }

    @Test("A prepared directory with an invalid Project is refused")
    func configWithInvalidProjectRefused() async throws {
        let prepared = ConfigurationDirectory()
        try prepared.writeMachineFile()
        try prepared.writeProjectFile(id: "broken", "id = \"broken\"\n")
        let destination = ConfigurationDirectory()
        let board = await preparedBoard()
        let arguments = makeArguments(
            initialize: false, config: prepared.path, linearClientID: nil, operatorID: "user-op"
        )
        let setup = try makeSetup(arguments: arguments, directory: destination, board: board)

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(!FileManager.default.fileExists(
            atPath: destination.url.appending(component: "config.toml").path(percentEncoded: false)
        ))
    }
}
