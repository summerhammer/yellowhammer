import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: --project filter")
struct DoctorProjectFilterTests {
    @Test("A sibling Project's failing findings are dropped; machine-scoped findings remain")
    func siblingFindingsDroppedMachineScopedRemain() async throws {
        let fixture = DoctorGitFixture()
        await fixture.initRepo()
        let missing = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "alpha", """
            id = "alpha"
            name = "alpha"
            linear_project = "alpha"
            spec_source = "\(fixture.path)"

            [[repos]]
            name = "backend"
            path = "\(fixture.path)"
            role = "backend"
            check = "swift test"
            """)
        try directory.writeValidProjectFile(id: "beta", repoPath: missing.path(percentEncoded: false))

        let doctor = makeDoctor(
            directory: directory, checks: [.configuration, .git, .linear, .orphans],
            projectFilter: ProjectID(rawValue: "alpha")
        )
        let findings = await doctor.run()

        #expect(!findings.contains { $0.subject.contains("beta") })
        #expect(!findings.contains { $0.check == .git && $0.severity == .failure })
        #expect(findings.contains { $0.check == .configuration && $0.severity == .pass && $0.subject == "alpha" })
        #expect(findings.contains { $0.check == .git && $0.severity == .pass })
        #expect(findings.contains { $0.check == .git && $0.subject == "git" })
        #expect(findings.contains { $0.check == .linear })
    }

    @Test("The filter keeps that Project's launchd and configuration findings, and drops the sibling's")
    func launchdAndConfigurationScopedToFilter() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        let doctor = makeDoctor(
            directory: directory, checks: [.configuration, .launchd], projectFilter: ProjectID(rawValue: "alpha")
        )
        let findings = await doctor.run()

        let launchdFindings = findings.filter { $0.check == .launchd }
        #expect(!launchdFindings.isEmpty)
        #expect(launchdFindings.allSatisfy { $0.subject.contains("alpha") })
        #expect(findings.contains { $0.check == .configuration && $0.subject == "alpha" })
        #expect(!findings.contains { $0.check == .configuration && $0.subject == "beta" })
    }

    @Test("Orphans are still computed against every Project: a sibling's installed plist is not orphaned")
    func orphansStillComputedAgainstAllProjects() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agentsDirectory = home.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let betaLabel = "com.summerhammer.yellowhammer.beta.author"
        try Data().write(to: agentsDirectory.appending(component: "\(betaLabel).plist"))

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        let doctor = makeDoctor(
            directory: directory, homeDirectory: home, checks: [.configuration, .orphans],
            projectFilter: ProjectID(rawValue: "alpha")
        )
        let findings = await doctor.run()

        #expect(!findings.contains { $0.check == .orphans })
    }

    @Test("An invalid Project file matched by <id>.toml is kept under that filter")
    func invalidProjectFileKeptUnderFilenameFilter() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeProjectFile(id: "ghost", "not valid toml [[[")

        let doctor = makeDoctor(
            directory: directory, checks: [.configuration], projectFilter: ProjectID(rawValue: "ghost")
        )
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .configuration && $0.severity == .failure })
        #expect(!findings.contains { $0.subject == "alpha" })
    }

    @Test("An unknown --project prints the exact message and fails, without misleading pass lines")
    func unknownProjectFilterMessageAndFailure() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(
            directory: directory, checks: [.configuration], projectFilter: ProjectID(rawValue: "ghost")
        )
        let findings = await doctor.run()

        #expect(findings.contains {
            $0.check == .configuration && $0.severity == .failure
                && $0.message == "no Project ghost in configuration"
        })
        #expect(!findings.contains { $0.severity == .pass })
    }

    @Test("No filter leaves every Project's findings in place")
    func noFilterKeepsEverything() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeValidProjectFile(id: "beta")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        #expect(findings.contains { $0.subject == "alpha" })
        #expect(findings.contains { $0.subject == "beta" })
    }
}
