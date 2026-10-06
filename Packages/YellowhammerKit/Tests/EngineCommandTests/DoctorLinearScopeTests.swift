import Domain
@testable import EngineCommand
import Testing

@Suite("Doctor: linear check, unreferenced, missing, team membership, filter and JSON")
struct DoctorLinearScopeTests {
    @Test("An unreferenced installation reports an info line naming the removal command, outside the tally")
    func unreferenced() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme")])
        let output = RecordingOutput()
        let findings = await fixture.doctor(output: output).run()

        let info = try #require(findings.linear("globex", subject: "connection").first)
        #expect(info.severity == .info)
        #expect(info.message.contains("yh config remove-board-connection globex"))
        #expect(info.message.contains("no Project uses"))
        #expect(info.message.hasPrefix("Board Connection globex (workspace \"Globex Corp\"; no Projects): "))
        // Its Keychain, authorization and Operator findings still run.
        #expect(findings.linear("globex", subject: "authorization").first?.severity == .pass)
        #expect(findings.linear("globex", subject: "operator").first?.severity == .pass)
        #expect(!findings.contains { $0.check == .linear && ($0.severity == .failure || $0.severity == .warning) })
        #expect(output.lines.contains { $0.hasPrefix("[info] linear: Board Connection globex") })
        // The summary counts only failures and warnings: the info line adds to neither.
        let others = findings.filter { $0.check != .linear && $0.severity == .warning }.count
        #expect(output.lines.last == "0 failed, \(others) warnings")
    }

    @Test("A Project naming an unregistered installation fails Check 1 and Check 4, naming both fixes")
    func missingInstallation() async throws {
        let fixture = try await DoctorLinearFixture(
            projects: [("alpha", "acme"), ("beta", "globex"), ("delta", "initech")]
        )
        let findings = await fixture.doctor().run()

        #expect(findings.contains {
            $0.check == .configuration && $0.severity == .failure && $0.projectID?.rawValue == "delta"
        })
        let linearFailures = findings.filter { $0.check == .linear && $0.severity == .failure }
        #expect(linearFailures.count == 1)
        let missing = try #require(linearFailures.first)
        #expect(missing.subject == "project")
        #expect(missing.projectID?.rawValue == "delta")
        #expect(missing.message.contains("initech"))
        #expect(missing.message.contains("yh setup --install-linear"))
        #expect(missing.message.contains("yh project remove delta"))
        #expect(!missing.message.hasPrefix("connection "))
        #expect(findings.linear("acme", subject: "authorization").first?.severity == .pass)
        #expect(findings.linear("globex", subject: "authorization").first?.severity == .pass)

        let rows = try #require(DoctorFindingRow.decodeLastLine([DoctorCommand.encodeFindingsJSON(findings)]))
        let row = try #require(rows.first { $0.subject == "project" })
        #expect(row.installation == "initech")
        #expect(row.projects == ["delta"])
        #expect(row.workspace == nil)
        #expect(row.workspaceName == nil)
    }

    @Test("--project delta keeps the missing-installation failure and drops the installations'")
    func missingInstallationUnderFilter() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme"), ("delta", "initech")])
        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "delta")).run()

        #expect(findings.contains {
            $0.check == .linear && $0.subject == "project" && $0.projectID?.rawValue == "delta"
        })
        #expect(findings.linear("acme").isEmpty)
    }

    @Test("Zero installations: no Projects is one info; a Project naming a missing one is its failure, no info")
    func zeroInstallations() async throws {
        let empty = ConfigurationDirectory()
        try empty.writeMachineFile("[github]\ncredential = \"keychain:github\"\n")
        let none = await makeDoctor(directory: empty, checks: [.configuration, .linear]).run()
        let linear = none.filter { $0.check == .linear }
        #expect(linear.count == 1)
        #expect(linear[0].severity == .info)
        #expect(linear[0].subject == "connection")
        #expect(linear[0].message.contains("no Linear workspace is connected"))

        let withProject = ConfigurationDirectory()
        try withProject.writeMachineFile("[github]\ncredential = \"keychain:github\"\n")
        try withProject.writeValidProjectFile(id: "alpha")
        let findings = await makeDoctor(directory: withProject, checks: [.configuration, .linear]).run()
        let linearFindings = findings.filter { $0.check == .linear }
        #expect(linearFindings.count == 1)
        #expect(linearFindings[0].severity == .failure)
        #expect(linearFindings[0].subject == "project")
        #expect(linearFindings[0].projectID?.rawValue == "alpha")
        #expect(linearFindings[0].message.contains("acme"))
    }

    @Test("Team membership: a non-member team fails naming the team and Settings → Members; members pass")
    func teamMembership() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme"), ("beta", "globex")])
        await fixture.acme.excludeMembership(of: engineeringTeam.id)
        let findings = await fixture.doctor().run()

        let failing = try #require(findings.linear("acme", subject: "team").first)
        #expect(failing.severity == .failure)
        #expect(failing.projectID?.rawValue == "alpha")
        #expect(failing.message.contains("ENG"))
        #expect(failing.message.contains("Settings → Members"))
        let passing = try #require(findings.linear("globex", subject: "team").first)
        #expect(passing.severity == .pass)
        #expect(passing.projectID?.rawValue == "beta")
        #expect(fixture.binds.calls.contains(.init(installation: "acme", linearProjectID: "lp-alpha")))
        #expect(fixture.binds.calls.contains(.init(installation: "globex", linearProjectID: "lp-beta")))
    }

    @Test("Team membership: forbidden is a permission refusal, never 'not visible'; scopeNotFound is not visible")
    func teamFailures() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme"), ("beta", "globex")])
        await fixture.acme.refuseNext(.forbidden("no"))
        await fixture.globex.refuseNext(.scopeNotFound("gone"))
        let findings = await fixture.doctor().run()

        let forbidden = try #require(findings.linear("acme", subject: "team").first)
        #expect(forbidden.severity == .failure)
        #expect(forbidden.message.contains("refused permission"))
        #expect(!forbidden.message.contains("not visible"))
        let hidden = try #require(findings.linear("globex", subject: "team").first)
        #expect(hidden.severity == .failure)
        #expect(hidden.message.contains("not visible to this connection"))
    }

    @Test("--project keeps only the filtered Project's installation and its own Project findings")
    func projectFilter() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme"), ("beta", "globex")])
        let findings = await fixture.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()

        #expect(!findings.linear("acme").isEmpty)
        #expect(findings.linear("globex").isEmpty)
        #expect(findings.linear("acme", subject: "team").allSatisfy { $0.projectID?.rawValue == "alpha" })

        let unreferenced = try await DoctorLinearFixture(projects: [("alpha", "acme")])
        let kept = await unreferenced.doctor(projectFilter: ProjectID(rawValue: "alpha")).run()
        #expect(kept.linear("globex").isEmpty)
    }

    @Test("JSON rows carry installation, workspace, workspace name and Projects; info rows say info")
    func jsonRows() async throws {
        let fixture = try await DoctorLinearFixture(projects: [("alpha", "acme"), ("gamma", "acme")])
        let findings = await fixture.doctor(checks: [.linear]).run()

        let rows = try #require(DoctorFindingRow.decodeLastLine([DoctorCommand.encodeFindingsJSON(findings)]))
        let auth = try #require(rows.first { $0.installation == "acme" && $0.subject == "authorization" })
        #expect(auth.workspace == "ws-acme")
        #expect(auth.workspaceName == "Acme Inc")
        #expect(auth.projects == ["alpha", "gamma"])
        #expect(auth.severity == "pass")
        let info = try #require(rows.first { $0.severity == "info" })
        #expect(info.installation == "globex")
        #expect(info.projects == [])
        let team = try #require(rows.first { $0.subject == "team" && $0.projects == ["alpha"] })
        #expect(team.installation == "acme")
        #expect(team.workspaceName == "Acme Inc")
    }
}
