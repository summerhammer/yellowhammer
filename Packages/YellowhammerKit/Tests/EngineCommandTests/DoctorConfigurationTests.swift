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
            code_hosting = { connection = "github" }
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

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"

            [cli.claude]

            [[routing]]
            work_kind = "*"
            route = "claude/haiku/low"
            """)
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .configuration && $0.severity == .warning })
        #expect(!findings.contains { $0.severity == .failure })
    }

    @Test("Verification route reachability warns in Check 1 (OQ154)")
    func verificationRouteReachabilityWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"

            [cli.claude]

            [[routing]]
            work_kind = "*"
            route = "claude/sonnet/medium"
            """)
        try directory.writeValidProjectFile(id: "alpha")

        let doctor = makeDoctor(directory: directory, checks: [.configuration])
        let findings = await doctor.run()

        let reachability = findings.first {
            $0.check == .configuration && $0.severity == .warning
                && $0.message.contains("Verification can fault")
        }
        let finding = try #require(reachability)
        #expect(finding.message.contains("VerificationDispatchFault"))
        #expect(finding.message.contains("every Cycle"))
        #expect(finding.message.contains(
            "remedy: add a fallback, or an authoring entry, whose Route no Work Card can resolve to"
        ))
        #expect(finding.message.contains("Route"))
        #expect(finding.message.contains("Work Kind"))
        #expect(finding.message.contains("Routing Table"))
        #expect(!findings.contains { $0.severity == .failure })
    }
}
