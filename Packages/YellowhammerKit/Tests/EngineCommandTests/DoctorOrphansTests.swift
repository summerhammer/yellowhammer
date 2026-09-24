@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: orphans check")
struct DoctorOrphansTests {
    private func makeAgentsDirectory() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agentsDirectory = home.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        return agentsDirectory
    }

    private func write(_ label: String, in agentsDirectory: URL) throws {
        try Data().write(to: agentsDirectory.appending(component: "\(label).plist"))
    }

    @Test("An orphan plist (no configured Project) fails")
    func orphanFound() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try write("com.summerhammer.yellowhammer.ghost.author", in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, homeDirectory: home, checks: [.configuration, .orphans])
        let findings = await doctor.run()

        #expect(findings.contains {
            $0.check == .orphans && $0.severity == .failure
                && $0.subject == "com.summerhammer.yellowhammer.ghost.author"
        })
    }

    @Test("A plist for a configured Project is not flagged")
    func configuredProjectNotFlagged() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try write("com.summerhammer.yellowhammer.alpha.author", in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, homeDirectory: home, checks: [.configuration, .orphans])
        let findings = await doctor.run()

        #expect(!findings.contains { $0.check == .orphans })
    }

    @Test("A plist for an invalid Project file is not flagged: misconfigured, not removed")
    func invalidProjectFileNotFlagged() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try write("com.summerhammer.yellowhammer.broken.author", in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "broken", "not valid toml [[[")

        let doctor = makeDoctor(directory: directory, homeDirectory: home, checks: [.configuration, .orphans])
        let findings = await doctor.run()

        #expect(!findings.contains { $0.check == .orphans })
    }

    @Test("An unrelated file is ignored")
    func unrelatedFileIgnored() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try write("com.example.other.thing", in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let doctor = makeDoctor(directory: directory, homeDirectory: home, checks: [.configuration, .orphans])
        let findings = await doctor.run()

        #expect(!findings.contains { $0.check == .orphans })
    }

    @Test("--fix with console answering y unloads and removes the orphan")
    func fixWithYesConfirmationRemoves() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let label = "com.summerhammer.yellowhammer.ghost.land"
        try write(label, in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let launchAgents = RecordingLaunchAgentControl()
        let console = ScriptedConsole(answers: ["y"])
        let doctor = makeDoctor(
            directory: directory, console: console, homeDirectory: home, launchAgents: launchAgents,
            fix: true, checks: [.configuration, .orphans]
        )
        let findings = await doctor.run()

        #expect(launchAgents.calls.contains(.bootout(label)))
        #expect(!FileManager.default.fileExists(atPath: agentsDirectory.appending(component: "\(label).plist").path))
        #expect(findings.contains { $0.check == .orphans && $0.severity == .pass })
        #expect(!findings.contains { $0.severity == .failure })
    }

    @Test("--fix with console answering n keeps the file")
    func fixWithNoAnswerKeeps() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let label = "com.summerhammer.yellowhammer.ghost.land"
        try write(label, in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let launchAgents = RecordingLaunchAgentControl()
        let console = ScriptedConsole(answers: ["n"])
        let doctor = makeDoctor(
            directory: directory, console: console, homeDirectory: home, launchAgents: launchAgents,
            fix: true, checks: [.configuration, .orphans]
        )
        let findings = await doctor.run()

        #expect(launchAgents.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentsDirectory.appending(component: "\(label).plist").path))
        #expect(findings.contains { $0.check == .orphans && $0.severity == .failure })
    }

    @Test("--fix with EOF keeps the file")
    func fixWithEOFKeeps() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let label = "com.summerhammer.yellowhammer.ghost.land"
        try write(label, in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let launchAgents = RecordingLaunchAgentControl()
        let console = ScriptedConsole(answers: [])
        let doctor = makeDoctor(
            directory: directory, console: console, homeDirectory: home, launchAgents: launchAgents,
            fix: true, checks: [.configuration, .orphans]
        )
        let findings = await doctor.run()

        #expect(launchAgents.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentsDirectory.appending(component: "\(label).plist").path))
        #expect(findings.contains { $0.check == .orphans && $0.severity == .failure })
    }

    @Test("--fix --yes removes without asking")
    func fixYesFlagRemovesWithoutAsking() async throws {
        let agentsDirectory = try makeAgentsDirectory()
        let home = agentsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let label = "com.summerhammer.yellowhammer.ghost.land"
        try write(label, in: agentsDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let launchAgents = RecordingLaunchAgentControl()
        let console = ScriptedConsole()
        let doctor = makeDoctor(
            directory: directory, console: console, homeDirectory: home, launchAgents: launchAgents,
            fix: true, yes: true, checks: [.configuration, .orphans]
        )
        let findings = await doctor.run()

        #expect(console.prompts.isEmpty)
        #expect(launchAgents.calls.contains(.bootout(label)))
        #expect(findings.contains { $0.check == .orphans && $0.severity == .pass })
    }
}
