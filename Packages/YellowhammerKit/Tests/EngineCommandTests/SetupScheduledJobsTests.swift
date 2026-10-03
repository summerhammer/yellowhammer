import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup, scheduled jobs: --install-jobs")
struct SetupScheduledJobsInstallTests {
    private func writeTwoProjects(_ directory: borrowing ConfigurationDirectory) throws {
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")
    }

    /// Runs `--init --install-jobs` for `alpha`/`beta` and returns the LaunchAgents directory, for the
    /// assertions below to split across.
    private func runTwoProjectInstall(
        homeDirectory: URL, launchAgents: RecordingLaunchAgentControl = RecordingLaunchAgentControl()
    ) async throws -> URL {
        let directory = ConfigurationDirectory()
        try writeTwoProjects(directory)
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        let board = await makeBoard(project: scope)
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board,
            homeDirectory: homeDirectory, yhExecutablePath: "/usr/local/bin/yh",
            setupTimePATH: "/opt/tools/bin:/usr/bin",
            fileExists: { $0 == "/opt/tools/bin/git" || $0 == "/opt/tools/bin/orca" },
            launchAgents: launchAgents
        )
        try await setup.run()
        return homeDirectory.appending(components: "Library", "LaunchAgents")
    }

    @Test("--init --install-jobs writes six plists, staggered by Project id, with the injected PATH")
    func installJobsWritesSixPlists() async throws {
        let homeDirectory = freshHomeDirectory()
        let launchAgentsDirectory = try await runTwoProjectInstall(homeDirectory: homeDirectory)

        let files = try FileManager.default.contentsOfDirectory(
            atPath: launchAgentsDirectory.path(percentEncoded: false)
        )
        #expect(Set(files) == Set([
            "dev.yellowhammer.alpha.author.plist",
            "dev.yellowhammer.alpha.build.plist",
            "dev.yellowhammer.alpha.land.plist",
            "dev.yellowhammer.beta.author.plist",
            "dev.yellowhammer.beta.build.plist",
            "dev.yellowhammer.beta.land.plist"
        ]))

        // alpha (stagger index 0): author fires at 22:00. beta (stagger index 1): author fires at 22:03.
        let alphaDecoded = try decodePlist(
            at: launchAgentsDirectory.appending(component: "dev.yellowhammer.alpha.author.plist")
        )
        let alphaProgramArguments = alphaDecoded["ProgramArguments"] as? [String]
        #expect(alphaProgramArguments == ["/usr/local/bin/yh", "author", "--project", "alpha"])
        let alphaIntervals = try #require(alphaDecoded["StartCalendarInterval"] as? [[String: Int]])
        #expect(alphaIntervals == [["Hour": 22, "Minute": 0]])
        let alphaPATH = try #require((alphaDecoded["EnvironmentVariables"] as? [String: String])?["PATH"])
        #expect(alphaPATH.contains("/opt/tools/bin"))

        let betaDecoded = try decodePlist(
            at: launchAgentsDirectory.appending(component: "dev.yellowhammer.beta.author.plist")
        )
        let betaIntervals = try #require(betaDecoded["StartCalendarInterval"] as? [[String: Int]])
        #expect(betaIntervals == [["Hour": 22, "Minute": 3]])
    }

    @Test("--init --install-jobs loads all six jobs, alpha's three before beta's three")
    func installJobsLoadsInOrder() async throws {
        let launchAgents = RecordingLaunchAgentControl()
        _ = try await runTwoProjectInstall(homeDirectory: freshHomeDirectory(), launchAgents: launchAgents)

        // Each job is bootout (ignored) + enable + bootstrap: 6 jobs * 3 calls.
        let labels = launchAgents.calls.compactMap { call -> String? in
            if case .bootstrap(let label) = call { return label }
            return nil
        }
        #expect(labels == [
            "dev.yellowhammer.alpha.author",
            "dev.yellowhammer.alpha.build",
            "dev.yellowhammer.alpha.land",
            "dev.yellowhammer.beta.author",
            "dev.yellowhammer.beta.build",
            "dev.yellowhammer.beta.land"
        ])
        #expect(launchAgents.calls.count == 18)
    }

    @Test("Re-running --install-jobs writes identical bytes and reloads")
    func installJobsIsIdempotent() async throws {
        let directory = ConfigurationDirectory()
        try writeTwoProjects(directory)
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let homeDirectory = freshHomeDirectory()

        let launchAgents1 = RecordingLaunchAgentControl()
        let setup1 = try makeSetup(
            arguments: arguments, directory: directory, board: board, homeDirectory: homeDirectory,
            launchAgents: launchAgents1
        )
        try await setup1.run()
        let url = homeDirectory.appending(
            components: "Library", "LaunchAgents", "dev.yellowhammer.alpha.author.plist"
        )
        let bytesAfterFirst = try Data(contentsOf: url)

        let launchAgents2 = RecordingLaunchAgentControl()
        let setup2 = try makeSetup(
            arguments: arguments, directory: directory, board: board, homeDirectory: homeDirectory,
            launchAgents: launchAgents2
        )
        try await setup2.run()
        let bytesAfterSecond = try Data(contentsOf: url)

        #expect(bytesAfterFirst == bytesAfterSecond)
        #expect(launchAgents2.calls.count == 18)
    }

    @Test("A Project whose provisioning fails gets no jobs; its sibling still does; setup throws")
    func provisioningFailureExcludesItsJobs() async throws {
        let directory = ConfigurationDirectory()
        try writeTwoProjects(directory)
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        )
        // alpha sorts first; its provisioning read is refused, beta's is not.
        await board.refuseNext(.refused("boom"))
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let homeDirectory = freshHomeDirectory()
        let launchAgents = RecordingLaunchAgentControl()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, homeDirectory: homeDirectory,
            launchAgents: launchAgents
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        let launchAgentsDirectory = homeDirectory.appending(components: "Library", "LaunchAgents")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: launchAgentsDirectory.path(percentEncoded: false)
        )
        #expect(Set(files) == Set([
            "dev.yellowhammer.beta.author.plist",
            "dev.yellowhammer.beta.build.plist",
            "dev.yellowhammer.beta.land.plist"
        ]))
    }

    @Test("A bootstrap failure is reported and makes setup throw")
    func bootstrapFailureThrows() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard()
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let homeDirectory = freshHomeDirectory()
        let launchAgents = RecordingLaunchAgentControl(
            failingLabels: ["dev.yellowhammer.alpha.author"]
        )
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, output: output, homeDirectory: homeDirectory,
            launchAgents: launchAgents
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(output.lines.contains { $0.contains("could not load dev.yellowhammer.alpha.author") })
    }
}
