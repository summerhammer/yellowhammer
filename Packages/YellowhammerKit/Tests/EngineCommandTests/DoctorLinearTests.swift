import Domain
@testable import EngineCommand
import Testing

@Suite("Doctor: linear check")
struct DoctorLinearTests {
    @Test("Pair present, members OK and operator active passes")
    func fullyHealthyPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"
            operator = "user-op"

            [github]
            credential = "keychain:github"
            """)
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        #expect(!findings.contains { $0.severity == .failure })
        #expect(findings.contains { $0.check == .linear && $0.severity == .pass && $0.subject == "authorization" })
        #expect(findings.contains { $0.check == .linear && $0.severity == .pass && $0.subject == "operator" })
    }

    @Test("No Installation token pair fails, naming the setup fix, and skips the rest of the check")
    func missingInstallationFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])

        let doctor = makeDoctor(
            directory: directory, board: board, credentials: RecordingCredentialStore(),
            checks: [.configuration, .linear]
        )
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].subject == "installation")
        #expect(linearFindings[0].message.contains("re-run the Linear step: yh setup --install-linear"))
    }

    @Test("A revoked or expired Installation (notAuthenticated) fails, naming who must approve it again")
    func notAuthenticatedFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])
        await board.refuseWorkspaceMembersNext(.notAuthenticated("token revoked"))

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].subject == "authorization")
        #expect(linearFindings[0].message.contains("re-run the Linear step: yh setup --install-linear"))
        // The app's Health group tells a revoked Installation from an unreachable Linear by this word.
        #expect(linearFindings[0].message.contains("revoked"))
    }

    @Test("Linear unreachable fails with a plain network message")
    func unreachableFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])
        await board.refuseWorkspaceMembersNext(.unreachable("timed out"))

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].message == "Linear could not be reached")
    }

    @Test("workspaceMembers() throwing some other failure still fails, generically")
    func workspaceMembersThrowingFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])
        await board.refuseWorkspaceMembersNext(.refused("no"))

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].message.contains("Linear authorization failed"))
    }

    @Test("A deactivated configured operator warns")
    func deactivatedOperatorWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"
            operator = "user-dead"

            [github]
            credential = "keychain:github"
            """)
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember, deactivatedMember])

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .linear && $0.subject == "operator" && $0.severity == .warning })
        #expect(!findings.contains { $0.severity == .failure })
    }

    @Test("No configured operator warns")
    func noOperatorConfiguredWarns() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let board = await makeBoard(members: [operatorMember])

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        #expect(findings.contains { $0.check == .linear && $0.subject == "operator" && $0.severity == .warning })
    }

    @Test("No App Installation configured: one installation failure naming the setup fix")
    func zeroInstallationsFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("[github]\ncredential = \"keychain:github\"\n")
        let board = await makeBoard(members: [operatorMember])

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].subject == "installation")
        #expect(linearFindings[0].message.contains("no Linear App Installation is configured"))
        #expect(linearFindings[0].message.contains("yh setup --install-linear"))
    }

    @Test("Two App Installations: one installation failure naming the count")
    func twoInstallationsFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            app_user = "app-user-1"

            [board.linear.installations.beta]
            credential = "keychain:linear-beta"
            workspace = "workspace-2"
            app_user = "app-user-2"

            [github]
            credential = "keychain:github"
            """)
        let board = await makeBoard(members: [operatorMember])

        let doctor = makeDoctor(directory: directory, board: board, checks: [.configuration, .linear])
        let findings = await doctor.run()

        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].subject == "installation")
        #expect(linearFindings[0].message.contains("declares 2 Linear App Installations"))
    }
}
