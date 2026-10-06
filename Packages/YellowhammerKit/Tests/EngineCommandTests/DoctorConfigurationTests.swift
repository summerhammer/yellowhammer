@testable import EngineCommand
import Testing

@Suite("Doctor: configuration check")
struct DoctorConfigurationTests {
    @Test("A valid directory yields no failures")
    func validDirectoryPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        #expect(!findings.contains { $0.severity == .failure })
        #expect(findings.contains { $0.check == .configuration && $0.severity == .pass })
    }

    @Test("An invalid Project file fails; a valid sibling still passes")
    func invalidProjectFailsSiblingPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeProjectFile(id: "broken", "not valid toml [[[")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .configuration && $0.severity == .failure })
        #expect(findings.contains {
            $0.check == .configuration && $0.severity == .pass && $0.subject == "alpha"
        })
    }

    @Test("A Project with an unknown template token fails, naming the key; a valid sibling still passes")
    func invalidTemplateFailsSiblingPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        try directory.writeProjectFile(id: "broken", """
            id = "broken"
            name = "broken"
            board = { linear = { connection = "acme", project = "broken" } }
            spec_source = "~/Developer/broken-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/broken-backend"
            role = "backend"
            check = "none"

            [git]
            commit_message = "{type}: {branch}"
            """)

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        let failure = try #require(findings.first { $0.check == .configuration && $0.severity == .failure })
        #expect(failure.message.contains("git.commit_message"))
        #expect(failure.message.contains("{branch}"))
        #expect(findings.contains {
            $0.check == .configuration && $0.severity == .pass && $0.subject == "alpha"
        })
    }

    @Test("A malformed machine file fails and stops every later check")
    func malformedMachineFileStopsLaterChecks() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("not valid toml [[[")
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory)
        let findings = await doctor.run()

        #expect(findings.count == 1)
        #expect(findings[0].check == .configuration)
        #expect(findings[0].severity == .failure)
    }

    @Test("A routing entry without fallbacks warns")
    func routingEntryWithoutFallbacksWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [github]
            credential = "keychain:github"

            [cli.claude]

            [[routing]]
            kind = "*"
            route = "claude/haiku/low"
            """)
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .configuration && $0.severity == .warning })
        #expect(!findings.contains { $0.severity == .failure })
    }
}
