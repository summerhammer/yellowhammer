import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup, scheduled jobs: --export-jobs, no-flag and interactive")
struct SetupScheduledJobsExportTests {
    @Test("--export-jobs writes plists without touching launchd")
    func exportJobsWritesPlistsOnly() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let exportDirectory = freshExportDirectory()
        let arguments = makeArguments(
            operatorID: "user-op", exportJobs: exportDirectory.path(percentEncoded: false), installation: "acme"
        )
        let launchAgents = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, launchAgents: launchAgents
        )

        try await setup.run()

        let files = try FileManager.default.contentsOfDirectory(
            atPath: exportDirectory.path(percentEncoded: false)
        )
        #expect(Set(files) == Set([
            "dev.yellowhammer.alpha.author.plist",
            "dev.yellowhammer.alpha.build.plist",
            "dev.yellowhammer.alpha.land.plist"
        ]))
        #expect(launchAgents.calls.isEmpty)
    }

    @Test("--export-jobs --cron writes one crontab file, PATH first, naming --project alpha")
    func exportJobsCronWritesCrontab() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let exportDirectory = freshExportDirectory()
        let arguments = makeArguments(
            operatorID: "user-op", exportJobs: exportDirectory.path(percentEncoded: false), cron: true,
            installation: "acme"
        )
        let setup = try makeSetup(arguments: arguments, directory: directory, board: board)

        try await setup.run()

        let crontabURL = exportDirectory.appending(component: "yellowhammer.crontab")
        let text = try String(contentsOf: crontabURL, encoding: .utf8)
        #expect(text.hasPrefix("PATH="))
        #expect(text.contains("--project alpha"))
    }

    @Test("--init with no jobs flag writes nothing and prints the guidance line")
    func initWithNoJobsFlagPrintsGuidance() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op", installation: "acme")
        let output = RecordingOutput()
        let homeDirectory = freshHomeDirectory()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, output: output, homeDirectory: homeDirectory
        )

        try await setup.run()

        #expect(output.lines.contains(
            "Scheduled jobs not installed; rerun with --install-jobs or --export-jobs <directory>."
        ))
        #expect(!FileManager.default.fileExists(
            atPath: homeDirectory.appending(components: "Library", "LaunchAgents").path(percentEncoded: false)
        ))
    }

    @Test("Interactive: answering 'n' installs nothing")
    func interactiveDeclinesJobs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let console = ScriptedConsole(answers: ["n", "n"])
        let homeDirectory = freshHomeDirectory()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, homeDirectory: homeDirectory
        )

        try await setup.run()

        #expect(!FileManager.default.fileExists(
            atPath: homeDirectory.appending(components: "Library", "LaunchAgents").path(percentEncoded: false)
        ))
    }

    @Test("Interactive: answering '' installs the jobs")
    func interactiveEmptyAnswerInstallsJobs() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let console = ScriptedConsole(answers: ["n", ""])
        let homeDirectory = freshHomeDirectory()
        let launchAgents = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, homeDirectory: homeDirectory,
            launchAgents: launchAgents
        )

        try await setup.run()

        let launchAgentsDirectory = homeDirectory.appending(components: "Library", "LaunchAgents")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: launchAgentsDirectory.path(percentEncoded: false)
        )
        #expect(files.count == 3)
    }

    @Test("A missing declared adapter under the composed PATH warns, and setup still succeeds")

    func missingToolWarnsButSucceeds() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"

            [github]
            credential = "keychain:github"

            [cli.orca]
            """)
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let output = RecordingOutput()
        let homeDirectory = freshHomeDirectory()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, output: output, homeDirectory: homeDirectory,
            setupTimePATH: "/usr/bin", fileExists: { _ in false }
        )

        try await setup.run()

        #expect(output.lines.contains { $0.hasPrefix("Warning:") && $0.contains("orca") })
        #expect(output.lines.contains("Setup complete."))
    }
}
