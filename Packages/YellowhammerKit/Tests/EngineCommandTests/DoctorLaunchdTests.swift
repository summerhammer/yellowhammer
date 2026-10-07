@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: launchd check")
struct DoctorLaunchdTests {
    @Test("An installed and loaded LaunchAgent passes")
    func installedAndLoadedPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agentsDirectory = home.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let label = "dev.yellowhammer.alpha.author"
        try Data().write(to: agentsDirectory.appending(component: "\(label).plist"))

        let doctor = makeDoctor(
            directory: directory, homeDirectory: home,
            launchAgents: RecordingLaunchAgentControl(loadedLabels: [label]),
            checks: [.configuration, .launchd]
        )
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .launchd && $0.subject == label && $0.severity == .pass })
    }

    @Test("A missing plist warns")
    func missingPlistWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .launchd])
        let findings = await doctor.run()

        let projectFindings = findings.filter { $0.check == .launchd && $0.projectID != nil }
        #expect(projectFindings.count == 3)
        #expect(projectFindings.allSatisfy { $0.severity == .warning })
    }

    @Test("A present but unloaded plist warns, not fails")
    func presentNotLoadedWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agentsDirectory = home.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let label = "dev.yellowhammer.alpha.build"
        try Data().write(to: agentsDirectory.appending(component: "\(label).plist"))

        let doctor = makeDoctor(
            directory: directory, homeDirectory: home,
            launchAgents: RecordingLaunchAgentControl(),
            checks: [.configuration, .launchd]
        )
        let findings = await doctor.run()

        let finding = findings.first { $0.check == .launchd && $0.subject == label }
        #expect(finding?.severity == .warning)
        #expect(!findings.contains { $0.severity == .failure })
    }
}
