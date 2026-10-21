import Domain
import Engine
import Foundation
import Journal
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
        await DoctorLinearFixture.recordSetup(
            of: fixture.acme, project: "lp-alpha", in: fixture.directory.url, for: ["alpha"], workspace: "ws-acme"
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
        // Two custom workflow states and the Card Type group; a missing group's labels are covered by the group.
        #expect(failures.count == 3)
        #expect(failures.contains { $0.message.contains("group label `Card Type` (team ENG) is missing") })
        #expect(!failures.contains { $0.message.contains("Night Card") })
        #expect(failures.allSatisfy { $0.message.contains("run `yh doctor --fix --check linear`") })
        #expect(await fixture.acme.creates == 0)
    }

    @Test("A missing label is read-only until repaired, then repair is idempotent")
    func missingUpgradeLabel() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.remove(label: "Night Card", team: engineeringTeam.id)
        let before = await fixture.acme.creates
        let project = ProjectID(rawValue: "alpha")
        let missing = await fixture.doctor(projectFilter: project).run()
        #expect(missing.linear("acme", subject: "provisioning").contains {
            $0.severity == .failure && $0.message.contains("Night Card")
                && $0.message.contains("yh doctor --fix --check linear")
        })
        #expect(await fixture.acme.creates == before)
        let repaired = await fixture.doctor(projectFilter: project, fix: true).run()
        #expect(repaired.linear("acme", subject: "provisioning").allSatisfy { $0.severity == .pass })
        #expect(await fixture.acme.creates == before + 1)
        _ = await fixture.doctor(projectFilter: project, fix: true).run()
        #expect(await fixture.acme.creates == before + 1)
    }

    @Test("Repair filters before mutations, including a sibling sharing the same Board Connection")
    func repairIsolation() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        let globexBefore = await fixture.globex.creates
        _ = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha"), fix: true).run()
        #expect(await fixture.acme.creates > 0)
        #expect(await fixture.globex.creates == globexBefore)
        #expect(fixture.binds.calls.allSatisfy {
            $0.installation == "acme" && ($0.linearProjectID.isEmpty || $0.linearProjectID == "lp-alpha")
        })
    }

    @Test("Repair refuses an unknown Project before touching any Board Connection")
    func unknownProjectDoesNotRepair() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "ghost"), fix: true).run()
        #expect(findings.contains { $0.severity == .failure && $0.check == .configuration })
        #expect(fixture.binds.calls.isEmpty)
        #expect(await fixture.acme.creates == 0)
    }

    @Test("Linear-only repair leaves jobs alone and creates no Route label")
    func mergedRoutesWithoutJobs() async throws {
        let fixture = try await DoctorLinearFixture(
            extraMachine: """
                [cli.claude]
                [[routing]]
                route = "claude/sonnet/medium"
                """,
            provisionAcme: false,
            projectExtras: ["alpha": """
                [[routing]]
                route = "claude/opus/high"
                """]
        )
        let jobs = RecordingLaunchAgentControl()
        let doctor = makeDoctor(
            directory: fixture.directory, boards: ["acme": fixture.acme, "globex": fixture.globex],
            credentials: DoctorLinearFixture.credentials, launchAgents: jobs, fix: true,
            checks: [.linear], projectFilter: ProjectID(rawValue: "alpha")
        )
        let findings = await doctor.run()
        #expect(!findings.contains { $0.severity == .failure })
        let labels = try await fixture.acme.labels(team: engineeringTeam.id)
        // The Card override is a description field: no Override group or Route label is created.
        #expect(!labels.contains { $0.name == "Override" || $0.name.contains("/") })
        #expect(jobs.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: doctor.launchAgentsDirectory.path()))
    }

    @Test("Repair requires both authorization and membership before any creates")
    func repairAuthorizationAndMembership() async throws {
        let unauthorized = try await DoctorLinearFixture(provisionAcme: false)
        let noCredentials = RecordingCredentialStore()
        _ = await unauthorized.doctor(
            credentials: noCredentials, projectFilter: ProjectID(rawValue: "alpha"), fix: true
        ).run()
        #expect(await unauthorized.acme.creates == 0)
        let nonMember = try await DoctorLinearFixture(provisionAcme: false)
        await nonMember.acme.excludeMembership(of: engineeringTeam.id)
        _ = await nonMember.doctor(projectFilter: ProjectID(rawValue: "alpha"), fix: true).run()
        #expect(await nonMember.acme.creates == 0)
    }

    @Test("Repair reports a refused create and preserves a colliding label")
    func refusedAndCollision() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.remove(label: "Night Card", team: engineeringTeam.id)
        await fixture.acme.script(.refuse(.forbidden("forbidden")), for: "Night Card")
        let project = ProjectID(rawValue: "alpha")
        let refused = await fixture.doctor(projectFilter: project, fix: true).run()
        #expect(refused.linear("acme", subject: "provisioning").contains {
            $0.severity == .failure && $0.message.contains("permission refused")
        })
        let existing = await fixture.acme.seed(label: "Night Card", team: engineeringTeam.id)
        let collision = await fixture.doctor(projectFilter: project, fix: true).run()
        #expect(collision.linear("acme", subject: "provisioning").contains {
            $0.severity == .failure && $0.message.contains("rename or delete")
        })
        #expect(try await fixture.acme.labels(team: engineeringTeam.id).contains { $0.id == existing })
    }

    @Test("A refused child in a newly created group remains an unfinished repair step")
    func createdGroupRefusedChild() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        await fixture.acme.script(.refuse(.forbidden("cannot create child")), for: "Night Card")
        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha"), fix: true).run()
        let provisioning = findings.linear("acme", subject: "provisioning")
        #expect(provisioning.count == 1)
        #expect(provisioning.first?.severity == .failure)
        #expect(provisioning.first?.message.contains("Night Card") == true)
        #expect(provisioning.first?.message.contains("permission refused") == true)
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

    @Test("An unrelated same-name Blocked is a failure naming the exact Board Mapping lines, and nothing is created")
    func unrelatedBlockedPrintsMappingLines() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        let unrelated = await fixture.acme.seed(state: "Blocked", team: engineeringTeam.id, category: .started)

        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        let failures = findings.linear("acme", subject: "provisioning").filter { $0.severity == .failure }
        let collision = try #require(failures.first { $0.message.contains("workflow state `Blocked`") })
        #expect(collision.message.contains("[board.linear.mapping]"))
        #expect(collision.message.contains("blocked = \"\(unrelated)\""))
        #expect(!collision.message.contains("to write them"), "doctor --fix never writes a mapping")
        #expect(await fixture.acme.creates == 0)
    }

    @Test("doctor --fix records the ids it creates in the Project's Journal, and a plain doctor then passes")
    func fixRecordsTheFootprint() async throws {
        let fixture = try await DoctorLinearFixture(provisionAcme: false)
        let project = ProjectID(rawValue: "alpha")

        let repaired = await fixture.doctor(projectFilter: project, fix: true).run()
        #expect(repaired.linear("acme", subject: "provisioning").allSatisfy { $0.severity == .pass })

        let journal = try JournalStore.open(
            configurationDirectory: fixture.directory.url, projectID: try #require(project),
            linearWorkspace: BoardObjectID(rawValue: "ws-acme")
        )
        let sources = Dictionary(uniqueKeysWithValues: try journal.boardFootprint().map { ($0.role, $0.source) })
        #expect(sources[.waitingOnYou] == .provisioned && sources[.blocked] == .provisioned)
        #expect(sources[.featureCard] == .provisioned && sources[.workCard] == .provisioned)
        let creates = await fixture.acme.creates

        let plain = await fixture.doctor(projectFilter: project).run()
        #expect(plain.linear("acme", subject: "provisioning").allSatisfy { $0.severity == .pass })
        #expect(await fixture.acme.creates == creates)
    }
}
