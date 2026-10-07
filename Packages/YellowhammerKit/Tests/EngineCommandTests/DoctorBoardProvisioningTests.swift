import Domain
import Engine
@testable import EngineCommand
import Testing

// Check 4's provisioning verification (#361): every provisioned item must exist, and a collision
// setup could not resolve is a failure until it is fixed — never a pass.

@Suite("Doctor: board provisioning verification")
struct DoctorBoardProvisioningTests {
    @Test("A provisioned board passes, naming the team")
    func provisionedBoardPasses() async throws {
        let fixture = try await DoctorLinearFixture()
        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let provisioning = findings.linear("acme", subject: "provisioning")
        #expect(provisioning.count == 1)
        #expect(provisioning.first?.severity == .pass)
        #expect(provisioning.first?.message.contains("team ENG") == true)
    }

    @Test("A board from the previous build: the Night Card collision fails, naming Object Type, until fixed")
    func previousBuildCollisionFails() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        let objectType = await fixture.acme.seed(label: "Object Type", team: engineeringTeam.id, isGroup: true)
        for child in ["Feature", "Card", "Night Card"] {
            await fixture.acme.seed(label: child, team: engineeringTeam.id, parent: objectType)
        }
        // Setup ran and reported the collision as an unfinished step.
        _ = try await BoardProvisioner.provision(
            using: fixture.acme, projectName: "lp-alpha", createIn: nil, routingTable: RoutingTable(entries: [])
        )
        let createsAfterSetup = await fixture.acme.creates

        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let failures = findings.linear("acme", subject: "provisioning").filter { $0.severity == .failure }
        let failure = try #require(failures.first)
        #expect(failures.count == 1)
        #expect(failure.projectID?.rawValue == "alpha")
        #expect(failure.message.contains("label `Night Card` in group `Card Type` (team ENG)"))
        #expect(failure.message.contains("label `Night Card` in group `Object Type`"))
        #expect(failure.message.contains("rename or delete"))
        // Verification never changes the board.
        #expect(await fixture.acme.creates == createsAfterSetup)
    }

    @Test("A board setup never provisioned fails once per missing state and group, and doctor creates nothing")
    func unprovisionedBoardFails() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)

        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let failures = findings.linear("acme", subject: "provisioning").filter { $0.severity == .failure }
        // Four workflow states and three label groups; a missing group's labels are covered by the group.
        #expect(failures.count == 7)
        #expect(failures.contains { $0.message.contains("group label `Card Type` (team ENG) is missing") })
        #expect(failures.contains { $0.message.contains("group label `Override` (team ENG) is missing") })
        #expect(!failures.contains { $0.message.contains("Night Card") })
        #expect(failures.allSatisfy { $0.message.contains("run `yh setup`") })
        #expect(await fixture.acme.creates == 0)
    }

    @Test("A board doctor cannot read fails the provisioning check, never passes it silently")
    func unreadableBoardFails() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.refuseLabelsNext(.unreachable("timed out"))

        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let provisioning = findings.linear("acme", subject: "provisioning")
        #expect(provisioning.count == 1)
        #expect(provisioning.first?.severity == .failure)
        #expect(provisioning.first?.message.contains("could not be read") == true)
    }

    @Test("A team Yellowhammer is not a member of is reported by the membership check only")
    func notAMemberIsNotReportedTwice() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.excludeMembership(of: engineeringTeam.id)

        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        #expect(findings.linear("acme", subject: "team").contains { $0.severity == .failure })
        #expect(findings.linear("acme", subject: "provisioning").isEmpty)
    }
}
