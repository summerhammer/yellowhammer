import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Orca ADE Repo registration: setup and Check 8")
struct OrcaRegistrationTests {
    private func seed(_ directory: borrowing ConfigurationDirectory) throws {
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha", repoPath: "/repos/backend", rehearsal: true)
        let file = directory.url.appending(components: "projects", "alpha.toml")
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "spec_source = \"~/Developer/alpha-spec\"", with: "") + """

            [[repos]]
            name = "spec"
            path = "/repos/spec"
            role = "spec"
            check = "none"
            """
        try directory.writeProjectFile(id: "alpha", text)
    }

    @Test("setup includes spec-role Repos, excludes Spec Sources, and reruns without mutation")
    func rerun() async throws {
        let directory = ConfigurationDirectory()
        try seed(directory)
        try directory.writeValidProjectFile(id: "beta", repoPath: "/repos/beta")
        let board = await makeBoard(project: BoardProjectScope(
            id: BoardObjectID(rawValue: "alpha"), name: "alpha", teams: [engineeringTeam]
        ))
        let workspace = RegistrationWorkspace(paths: ["/repos/backend/../backend/"])
        let setup = try makeSetup(
            arguments: makeArguments(operatorID: "user-op", installation: "acme"),
            directory: directory, board: board, workspace: workspace
        )
        try await setup.run()
        try await setup.run()
        #expect(workspace.additions == ["/repos/spec", "/repos/beta"])
        #expect(!workspace.additions.contains { $0.contains("beta-spec") })
        #expect(workspace.reads == 2)
    }

    @Test("registration refusal fails setup, names the Repo and Orca error, and excludes its jobs")
    func refusal() async throws {
        let directory = ConfigurationDirectory()
        try seed(directory)
        try directory.writeValidProjectFile(id: "beta", repoPath: "/repos/beta")
        let board = await makeBoard(project: BoardProjectScope(
            id: BoardObjectID(rawValue: "alpha"), name: "alpha", teams: [engineeringTeam]
        ))
        let workspace = RegistrationWorkspace(failures: [
            "/repos/spec": .refused(code: "denied", message: "cannot register")
        ])
        let jobs = RecordingLaunchAgentControl()
        let output = RecordingOutput()
        let home = FileManager.default.temporaryDirectory.appending(component: "yh-orca-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let setup = try makeSetup(
            arguments: makeArguments(operatorID: "user-op", installJobs: true, installation: "acme"),
            directory: directory, board: board, output: output, homeDirectory: home,
            workspace: workspace, launchAgents: jobs
        )
        await #expect(throws: SetupError.self) { try await setup.run() }
        #expect(output.lines.contains { $0.contains("Repo spec") && $0.contains("denied") })
        let loaded = jobs.calls.compactMap { call -> String? in
            if case .bootstrap(let label) = call { return label }
            return nil
        }
        #expect(loaded.count == 3)
        #expect(loaded.allSatisfy { $0.contains("beta") })
    }

    @Test("Check 8 is last, accepts --check orca, and emits scoped JSON failures with a remedy")
    func doctor() async throws {
        let directory = ConfigurationDirectory()
        try seed(directory)
        try directory.writeValidProjectFile(id: "beta", repoPath: "/repos/beta")
        let command = try DoctorCommand.parse(["--check", "orca", "--project", "alpha", "--json"])
        try command.validate()
        #expect(DoctorCheck.allCases.count == 8)
        #expect(DoctorCheck.allCases.last == .orca)
        let workspace = RegistrationWorkspace(paths: ["/repos/backend/../backend/"])
        let findings = await makeDoctor(
            directory: directory, workspace: workspace, checks: [.orca], projectFilter: ProjectID(rawValue: "alpha")!
        ).run().filter { $0.check == .orca }
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.check == .orca && $0.projectID?.rawValue == "alpha" })
        #expect(findings.contains { $0.severity == .pass && $0.message.contains("/repos/backend") })
        #expect(findings.contains {
            $0.severity == .failure && $0.message.contains("orca repo add --path /repos/spec")
        })
        let json = DoctorCommand.encodeFindingsJSON(findings)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(rows.allSatisfy { $0["check"] as? String == "orca" })
        #expect(rows.contains { $0["severity"] as? String == "failure" })
        #expect(workspace.additions.isEmpty)
    }

    @Test("unreachable Orca emits one machine failure and skips per-Repo findings, even with no Projects")
    func unavailable() async throws {
        let directory = ConfigurationDirectory()
        try seed(directory)
        let workspace = RegistrationWorkspace(readFailure: .unavailable("runtime offline"))
        let findings = await makeDoctor(
            directory: directory, workspace: workspace, checks: [.orca]
        ).run().filter { $0.check == .orca }
        #expect(findings.count == 1)
        #expect(findings.first?.projectID == nil)
        #expect(findings.first?.severity == .failure)
        #expect(findings.first?.message.contains("runtime offline") == true)
        let empty = ConfigurationDirectory()
        try empty.writeMachineFile()
        let emptyFindings = await makeDoctor(
            directory: empty, workspace: workspace, checks: [.orca]
        ).run().filter { $0.check == .orca }
        #expect(emptyFindings.count == 1)
    }
}

@Suite("Orca ADE unreachable setup")
struct OrcaUnavailableSetupTests {
    @Test("an unreachable runtime fails setup with its reason even without Projects")
    func unreachable() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(operatorID: "user-op", installation: "acme"),
            directory: directory, board: await makeBoard(), output: output,
            workspace: RegistrationWorkspace(readFailure: .unavailable("runtime offline"))
        )
        await #expect(throws: SetupError.self) { try await setup.run() }
        #expect(output.lines.contains { $0.contains("runtime offline") })
    }
}
