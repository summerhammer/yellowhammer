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
        homeDirectory: URL, launchAgents: RecordingLaunchAgentControl = RecordingLaunchAgentControl(),
        output: RecordingOutput = RecordingOutput()
    ) async throws -> URL {
        let directory = ConfigurationDirectory()
        try writeTwoProjects(directory)
        let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam])
        let board = await makeBoard(project: scope)
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, output: output,
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

        // New jobs need enable + bootstrap without unloading.
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
        #expect(launchAgents.calls.count == 12)
    }

    @Test("Re-running --install-jobs loads unchanged but unloaded jobs")
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
        #expect(launchAgents2.calls.count == 12)
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
    @Test("An unchanged loaded sibling is enabled without unloading",
           arguments: [LaunchAgentRuntimeState.idle, .running])
    func unchangedLoadedJob(state: LaunchAgentRuntimeState) async throws {
        let home = freshHomeDirectory()
        _ = try await runTwoProjectInstall(homeDirectory: home)
        let label = "dev.yellowhammer.alpha.author"
        let control = RecordingLaunchAgentControl(loadedLabels: [label], states: [label: [state]])
        _ = try await runTwoProjectInstall(homeDirectory: home, launchAgents: control)
        #expect(control.calls.contains(.enable(label)))
        #expect(!control.calls.contains(.bootout(label)))
        #expect(!control.calls.contains(.bootstrap(label)))
    }

    @Test("A running changed sibling keeps its plist while other jobs install",
           arguments: [[LaunchAgentRuntimeState.running], [.idle, .running]])
    func runningSibling(states: [LaunchAgentRuntimeState]) async throws {
        let home = freshHomeDirectory()
        let directory = home.appending(components: "Library", "LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "dev.yellowhammer.alpha.author"
        let url = directory.appending(component: label + ".plist")
        let old = Data("previous plist".utf8)
        try old.write(to: url)
        let control = RecordingLaunchAgentControl(states: [label: states])
        let output = RecordingOutput()
        _ = try await runTwoProjectInstall(homeDirectory: home, launchAgents: control, output: output)
        #expect(output.lines.contains { $0.contains("skipped running \(label)") && $0.contains("rerun") })
        #expect(try Data(contentsOf: url) == old)
        #expect(!control.calls.contains(.bootout(label)))
        #expect(!control.calls.contains(.bootstrap(label)))
        #expect(control.calls.contains(.bootstrap("dev.yellowhammer.beta.author")))
    }

    @Test("Changed idle jobs reload; inspection/unload failures preserve the prior plist",
           arguments: ["success", "inspection", "enable", "bootout", "bootstrap", "recovery"])
    func replacementSafety(scenario: String) async throws {
        let home = freshHomeDirectory()
        let directory = home.appending(components: "Library", "LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "dev.yellowhammer.alpha.author"
        let url = directory.appending(component: label + ".plist")
        let old = Data("previous plist".utf8)
        try old.write(to: url)
        let control = RecordingLaunchAgentControl(
            failingLabels: scenario == "enable" ? [label] : [],
            loadedLabels: [label], inspectionFailures: scenario == "inspection" ? [label] : [],
            bootoutFailures: scenario == "bootout" ? [label] : [],
            bootstrapFailures: [label: scenario == "bootstrap" ? 1 : scenario == "recovery" ? 2 : 0]
        )
        let output = RecordingOutput()
        if scenario == "success" {
            _ = try await runTwoProjectInstall(homeDirectory: home, launchAgents: control)
            #expect(try Data(contentsOf: url) != old)
            #expect(control.calls.filter { $0 == .bootout(label) }.count == 1)
        } else {
            await #expect(throws: SetupError.self) {
                _ = try await runTwoProjectInstall(homeDirectory: home, launchAgents: control, output: output)
            }
            #expect(try Data(contentsOf: url) == old)
            if scenario == "inspection" || scenario == "enable" || scenario == "bootout" {
                #expect(!control.calls.contains(.bootstrap(label)))
            } else {
                #expect(control.calls.filter { $0 == .bootstrap(label) }.count == 2)
                #expect(output.lines.contains { $0.contains("could not load \(label): bootstrap failed") })
                if scenario == "recovery" {
                    #expect(output.lines.contains {
                        $0.contains("could not restore previous \(label): bootstrap failed")
                    })
                    #expect(!output.lines.contains { $0.contains("restored previous") })
                } else {
                    #expect(output.lines.contains { $0.contains("restored previous \(label)") })
                }
            }
        }
    }
}
