@testable import EngineCommand
import Foundation
import Testing

// verification/verify-a-feature-clause-by-clause: a Repo that declares `check = none` covers no build or test
// clause, so doctor says so when the Repo has tests it could run.

@Suite("Doctor: check = none with test targets")
struct DoctorNoCheckTests {
    private func writeProject(
        _ directory: borrowing ConfigurationDirectory, repoPath: String, check: String
    ) throws {
        try directory.writeProjectFile(id: "alpha", """
            id = "alpha"
            name = "alpha"
            board = { linear = { connection = "acme", project = "alpha" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/alpha-spec"

            [[repos]]
            name = "backend"
            path = "\(repoPath)"
            role = "backend"
            check = "\(check)"
            """)
    }

    private func addTestsDirectory(to fixture: borrowing DoctorGitFixture) throws {
        try FileManager.default.createDirectory(
            at: fixture.url.appending(component: "Tests", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func noCheckFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
        findings.filter { $0.severity == .info && $0.message.contains("declares `check = none`") }
    }

    @Test("A Repo with check = none and a Tests directory gets an informational finding")
    func testsDirectoryWithNoCheckIsReported() async throws {
        let fixture = DoctorGitFixture()
        await fixture.initRepo()
        try addTestsDirectory(to: fixture)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, repoPath: fixture.path, check: "none")

        let findings = await makeDoctor(directory: directory, checks: [.configuration, .git]).run()

        let notes = noCheckFindings(findings)
        #expect(notes.count == 1)
        #expect(notes.first?.message.contains("Tests/") == true)
        #expect(notes.first?.message.contains("`not checked`") == true)
        #expect(notes.first?.message.contains("projects/alpha.toml") == true)
    }

    @Test("A Package.swift that declares a testTarget counts as test targets")
    func packageManifestWithTestTargetIsReported() async throws {
        let fixture = DoctorGitFixture()
        await fixture.initRepo()
        try "let package = Package(targets: [.testTarget(name: \"AppTests\")])"
            .write(to: fixture.url.appending(component: "Package.swift"), atomically: true, encoding: .utf8)
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, repoPath: fixture.path, check: "none")

        let findings = await makeDoctor(directory: directory, checks: [.configuration, .git]).run()

        #expect(noCheckFindings(findings).first?.message.contains("Package.swift declares a testTarget") == true)
    }

    @Test("check = none without test targets, or a real check with them, is silent")
    func silentWhenNothingToSay() async throws {
        let bare = DoctorGitFixture()
        await bare.initRepo()
        let tested = DoctorGitFixture()
        await tested.initRepo()
        try addTestsDirectory(to: tested)

        let bareDirectory = ConfigurationDirectory()
        try bareDirectory.writeMachineFile()
        try writeProject(bareDirectory, repoPath: bare.path, check: "none")
        let bareFindings = await makeDoctor(directory: bareDirectory, checks: [.configuration, .git]).run()
        #expect(noCheckFindings(bareFindings).isEmpty)

        let testedDirectory = ConfigurationDirectory()
        try testedDirectory.writeMachineFile()
        try writeProject(testedDirectory, repoPath: tested.path, check: "swift test")
        let testedFindings = await makeDoctor(directory: testedDirectory, checks: [.configuration, .git]).run()
        #expect(noCheckFindings(testedFindings).isEmpty)
    }
}
