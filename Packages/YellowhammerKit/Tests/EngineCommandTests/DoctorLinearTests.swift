import Domain
@testable import EngineCommand
import Testing

@Suite("Doctor: linear check")
struct DoctorLinearTests {
    @Test("Pair present, members OK and operator active passes")
    func fullyHealthyPasses() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [linear]
            credential = "keychain:linear"
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
        #expect(linearFindings[0].message.contains("re-run the Linear step of yh setup"))
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
        #expect(linearFindings[0].message.contains("a workspace admin must approve the app again"))
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
            [linear]
            credential = "keychain:linear"
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
}
