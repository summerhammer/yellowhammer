@testable import EngineCommand
import Foundation
import Testing

@Suite("Doctor: git version parsing")
struct GitVersionParsingTests {
    @Test("A version at or above 2.38 parses and meets the minimum")
    func meetsMinimum() {
        let version = GitVersion.parse("git version 2.39.5 (Apple Git-154)")
        #expect(version == GitVersion(major: 2, minor: 39, patch: 5))
        #expect(version?.meets(minimumMajor: 2, minimumMinor: 38) == true)
    }

    @Test("2.37.1 parses but does not meet the minimum")
    func belowMinimum() {
        let version = GitVersion.parse("git version 2.37.1")
        #expect(version == GitVersion(major: 2, minor: 37, patch: 1))
        #expect(version?.meets(minimumMajor: 2, minimumMinor: 38) == false)
    }

    @Test("Exactly 2.38.0 meets the minimum")
    func exactlyMinimum() {
        let version = GitVersion.parse("git version 2.38.0")
        #expect(version?.meets(minimumMajor: 2, minimumMinor: 38) == true)
    }

    @Test("A future major version meets the minimum")
    func futureMajorMeetsMinimum() {
        let version = GitVersion.parse("git version 3.0.0")
        #expect(version?.meets(minimumMajor: 2, minimumMinor: 38) == true)
    }

    @Test("Unparseable output fails to parse")
    func unparseableFailsToParse() {
        #expect(GitVersion.parse("not a version string") == nil)
        #expect(GitVersion.parse("") == nil)
        #expect(GitVersion.parse("git version 2") == nil)
    }
}

@Suite("Doctor: git check")
struct DoctorGitTests {
    @Test("A real git work tree passes")
    func realGitWorkTreePasses() async throws {
        let fixture = DoctorGitFixture()
        await fixture.initRepo()

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", repoPath: fixture.path)

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .git])
        let findings = await doctor.run()

        #expect(findings.contains {
            $0.check == .git && $0.severity == .pass && $0.subject.contains("Project alpha repo backend")
        })
    }

    @Test("A plain directory (not a git repository) fails")
    func plainDirectoryFails() async throws {
        let plain = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-plain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", repoPath: plain.path(percentEncoded: false))

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .git])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .git && $0.severity == .failure })
    }

    @Test("A missing path fails")
    func missingPathFails() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-missing-\(UUID().uuidString)", directoryHint: .isDirectory)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", repoPath: missing.path(percentEncoded: false))

        let doctor = makeDoctor(directory: directory, checks: [.configuration, .git])
        let findings = await doctor.run()

        #expect(findings.contains {
            $0.check == .git && $0.severity == .failure && $0.message.contains("does not exist")
        })
    }

    @Test("A `~`-prefixed path expands against the injected home directory, not the real one")
    func tildeExpandsAgainstInjectedHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let fixture = DoctorGitFixture(name: "tilde")
        await fixture.initRepo()
        let repoName = fixture.url.lastPathComponent
        let relocated = home.appending(component: repoName, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: fixture.url, to: relocated)

        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", repoPath: "~/\(repoName)")

        let doctor = makeDoctor(directory: directory, homeDirectory: home, checks: [.configuration, .git])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .git && $0.severity == .pass })
    }
}
