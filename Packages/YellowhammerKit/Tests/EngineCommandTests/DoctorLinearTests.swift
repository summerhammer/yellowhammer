import Domain
@testable import EngineCommand
import Testing

@Suite("Doctor: linear check, per App Installation")
struct DoctorLinearTests {
    @Test("Both healthy: each installation passes, naming its workspace and Projects, bound once by name")
    func bothHealthy() async throws {
        let fixture = try await DoctorLinearFixture()
        let findings = await fixture.doctor().run()

        #expect(!findings.contains { $0.check == .linear && ($0.severity == .failure || $0.severity == .warning) })
        let acmeAuth = try #require(findings.linear("acme", subject: "authorization").first)
        #expect(acmeAuth.severity == .pass)
        #expect(acmeAuth.message
            == #"installation acme (workspace "Acme Inc"; Projects alpha, gamma): Linear authorization succeeded"#)
        #expect(findings.linear("acme", subject: "operator").first?.severity == .pass)
        let globexAuth = try #require(findings.linear("globex", subject: "authorization").first)
        #expect(globexAuth.message
            == #"installation globex (workspace "Globex Corp"; Projects beta): Linear authorization succeeded"#)
        #expect(findings.linear("globex", subject: "operator").first?.severity == .pass)
        let workspaceBinds = fixture.binds.calls.filter { $0.linearProjectID.isEmpty }
        #expect(workspaceBinds.map(\.installation) == ["acme", "globex"])
    }

    @Test("Keychain missing on acme only: acme fails with the re-connect fix, globex is unaffected")
    func keychainMissing() async throws {
        let fixture = try await DoctorLinearFixture()
        let credentials = RecordingCredentialStore(seed: ["keychain:linear-globex": "secret"])
        let findings = await fixture.doctor(credentials: credentials).run()

        let acme = findings.linear("acme")
        #expect(acme.count == 1)
        #expect(acme[0].severity == .failure)
        #expect(acme[0].subject == "installation")
        #expect(acme[0].message.contains("yh setup --install-linear --installation acme"))
        #expect(acme[0].message.contains("Settings → Linear workspaces"))
        #expect(!acme[0].message.contains("workspace \""))
        #expect(findings.linear("globex", subject: "authorization").first?.severity == .pass)
    }

    @Test("acme revoked: failure containing revoked and the workspace, globex passes")
    func revoked() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.refuseWorkspaceMembersNext(.notAuthenticated("token revoked"))
        let findings = await fixture.doctor().run()

        let acme = try #require(findings.linear("acme", subject: "authorization").first)
        #expect(acme.severity == .failure)
        #expect(acme.message.contains("revoked"))
        #expect(acme.message.contains(#"workspace "Acme Inc""#))
        #expect(acme.message.contains("--installation acme"))
        #expect(findings.linear("acme", subject: "operator").isEmpty)
        #expect(findings.linear("acme", subject: "team").isEmpty)
        #expect(findings.linear("globex", subject: "authorization").first?.severity == .pass)
    }

    @Test("acme unreachable: Linear could not be reached, globex passes")
    func unreachable() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.refuseWorkspaceMembersNext(.unreachable("timed out"))
        let findings = await fixture.doctor().run()

        let acme = try #require(findings.linear("acme", subject: "authorization").first)
        #expect(acme.severity == .failure)
        #expect(acme.message.hasSuffix("Linear could not be reached"))
        #expect(findings.linear("globex", subject: "authorization").first?.severity == .pass)
    }

    @Test("Another authorization failure fails generically")
    func otherFailure() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.refuseWorkspaceMembersNext(.refused("no"))
        let findings = await fixture.doctor().run()

        let acme = try #require(findings.linear("acme", subject: "authorization").first)
        #expect(acme.severity == .failure)
        #expect(acme.message.contains("Linear authorization failed"))
    }

    @Test("Operator missing on acme, stale on globex: each warns, scoped to its installation")
    func operatorWarnings() async throws {
        let fixture = try await DoctorLinearFixture(operators: ["globex": "user-gone"])
        let findings = await fixture.doctor().run()

        let acme = try #require(findings.linear("acme", subject: "operator").first)
        #expect(acme.severity == .warning)
        #expect(acme.message.contains("yh config operator --installation acme"))
        #expect(acme.message.contains("alpha, gamma"))
        #expect(acme.message.contains("unassigned"))
        let globex = try #require(findings.linear("globex", subject: "operator").first)
        #expect(globex.severity == .warning)
        #expect(globex.message.contains("no longer a candidate"))
        #expect(globex.installation?.projects.map(\.rawValue) == ["beta"])
    }

    @Test("A failed workspace name read leaves acme named by its local name alone; globex keeps its name")
    func workspaceNameReadFails() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.failWorkspace(with: .unreachable("no"))
        let findings = await fixture.doctor().run()

        let acme = try #require(findings.linear("acme", subject: "authorization").first)
        #expect(acme.severity == .pass)
        #expect(acme.message == "installation acme (Projects alpha, gamma): Linear authorization succeeded")
        #expect(acme.installation?.workspaceName == nil)
        #expect(!findings.contains { $0.message.contains("could not read") })
        #expect(findings.linear("globex", subject: "authorization").first?.message.contains("Globex Corp") == true)
    }

    @Test("The authorization field: authorized, refused (revoked, keychain absent), unreachable")
    func authorizationField() async throws {
        let fixture = try await DoctorLinearFixture()
        await fixture.acme.refuseWorkspaceMembersNext(.notAuthenticated("revoked"))
        await fixture.globex.refuseWorkspaceMembersNext(.unreachable("timed out"))
        let findings = await fixture.doctor().run()
        #expect(findings.linear("acme", subject: "authorization").first?.authorization == .refused)
        #expect(findings.linear("globex", subject: "authorization").first?.authorization == .unreachable)

        let healthy = await fixture.doctor().run()
        #expect(healthy.linear("acme", subject: "authorization").first?.authorization == .authorized)
        #expect(healthy.linear("acme", subject: "operator").first?.authorization == nil)

        let credentials = RecordingCredentialStore(seed: ["keychain:linear-globex": "secret"])
        let absent = await fixture.doctor(credentials: credentials).run()
        #expect(absent.linear("acme", subject: "installation").first?.authorization == .refused)
    }

    @Test("An unreadable Keychain item is an authorization failure, unreachable, with no live call")
    func unreadableKeychain() async throws {
        let fixture = try await DoctorLinearFixture()
        let credentials = RecordingCredentialStore(
            seed: ["keychain:linear-globex": "secret"], unreadable: ["keychain:linear-acme"]
        )
        let findings = await fixture.doctor(credentials: credentials).run()

        let acme = findings.linear("acme")
        #expect(acme.count == 1)
        #expect(acme[0].subject == "authorization")
        #expect(acme[0].severity == .failure)
        #expect(acme[0].authorization == .unreachable)
        #expect(acme[0].message.contains("Keychain item"))
        #expect(acme[0].message.contains("could not be read"))
        #expect(!acme[0].message.contains("token pair"))
        #expect(DoctorCommand.encodeFindingsJSON(acme).contains(#""authorization":"unreachable""#))
    }
}
