import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// Writes a Project whose Repos are `~/dev/<id>-<name>`, so the stub's slug for one is `acme/<id>-<name>`.
private func writeProject(
    _ directory: borrowing ConfigurationDirectory, id: String,
    repos: [(name: String, role: String)] = [("backend", "backend")], credential: String? = nil
) throws {
    // A Project declares exactly one specification source: a `spec` role Repo or a `spec_source`.
    let specSource = repos.contains { $0.role == "spec" } ? "" : "spec_source = \"~/Developer/\(id)-spec\"\n"
    let github = credential.map { "\n[github]\ncredential = \"\($0)\"\n" } ?? ""
    let declarations = repos.map {
        """

        [[repos]]
        name = "\($0.name)"
        path = "~/dev/\(id)-\($0.name)"
        role = "\($0.role)"
        check = "swift test"
        """
    }.joined()
    try directory.writeProjectFile(id: id, """
        id = "\(id)"
        name = "\(id)"
        board = { linear = { connection = "acme", project = "\(id)" } }
        \(specSource)\(github)\(declarations)
        """)
}

private func gitHubFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
    findings.filter { $0.check == .github }
}

@Suite("Doctor: GitHub credential check")
struct DoctorGitHubTests {
    @Test("A valid token that can push to every working Repo passes, naming the login")
    func passes() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile")])
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.pass, .pass, .pass])
        #expect(findings.map(\.subject) == ["credential", "repo backend", "repo mobile"])
        #expect(findings.allSatisfy { $0.projectID == ProjectID(rawValue: "alpha") })
        #expect(findings[0].message.contains("octocat"))
        #expect(findings[1].message.contains("Repo backend (acme/alpha-backend)"))
        #expect(transport.paths == ["/user", "/repos/acme/alpha-backend", "/repos/acme/alpha-mobile"])
    }

    @Test("A missing Keychain item fails, naming the reference, the item and the fix, and asks GitHub nothing")
    func missingItem() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(seed: ["keychain:linear": "x"]),
            gitHub: transport.validation(), checks: [.github]
        ).run())

        let failure = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(failure.severity == .failure)
        #expect(failure.projectID == ProjectID(rawValue: "alpha"))
        #expect(failure.message.contains("keychain:github"))
        #expect(failure.message.contains("dev.yellowhammer"))
        #expect(failure.message.contains("yh setup --install-github"))
        #expect(transport.requests.isEmpty)
    }

    @Test("A Keychain item that cannot be read fails")
    func unreadableItem() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(unreadable: ["keychain:github"]),
            gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.failure])
        #expect(findings[0].message.contains("could not be read"))
        #expect(transport.requests.isEmpty)
    }

    @Test("A token GitHub rejects fails, without checking any Repo, and never prints the token")
    func rejected() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/user": .unauthorized])
        let doctor = makeDoctor(
            directory: directory, output: RecordingOutput(), gitHub: transport.validation(), checks: [.github]
        )

        let findings = gitHubFindings(await doctor.run())

        #expect(findings.map(\.severity) == [.failure])
        #expect(findings[0].message.contains("rejected"))
        #expect(!findings[0].message.contains("ghp_test-secret"))
        #expect(transport.paths == ["/user"])
    }

    @Test("A Repo the token cannot push to fails on its own row; the others pass")
    func noPushOnOneRepo() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile")])
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-mobile": .repo(push: false)])

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.pass, .pass, .failure])
        #expect(findings[2].subject == "repo mobile")
        #expect(findings[2].message.contains("Repo mobile (acme/alpha-mobile): the token lacks push permission"))
    }

    @Test("A classic token without the repo scope fails with the missing scope named")
    func missingScope() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/user": .user(scopes: "gist")])

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.pass, .failure])
        #expect(findings[1].message.contains("lacks the repo scope"))
    }

    @Test("A Repo that is not found fails; a Repo with no GitHub origin fails")
    func notFoundAndNotGitHub() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(
            directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile"), ("web", "web")]
        )
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-mobile": .notFound])
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let webPath = Doctor.expandTilde("~/dev/alpha-web", homeDirectory: home.path(percentEncoded: false))

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, homeDirectory: home,
            gitHub: transport.validation(notGitHub: [webPath]), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.pass, .pass, .failure, .failure])
        #expect(findings[2].message.contains("not found or not accessible with this token"))
        #expect(findings[3].message.contains("not a GitHub repository"))
    }

    @Test("A fine-grained token is a pass that says its write access cannot be confirmed")
    func fineGrained() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/user": .user(scopes: nil)])

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.pass, .pass])
        #expect(findings[1].message.contains("cannot be confirmed without writing"))
    }

    @Test("GitHub being unreachable is a warning, not a failure")
    func unreachable() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/user": StubGitHubTransport.Reply(503)])

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.warning])
    }

    @Test("A Repo whose role is spec is not checked")
    func specRepoSkipped() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("spec", "spec")])
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-spec": .repo(push: false)])

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.subject) == ["credential", "repo backend"])
        #expect(findings.allSatisfy { $0.severity == .pass })
        #expect(!transport.paths.contains("/repos/acme/alpha-spec"))
    }

    @Test("A Project's own credential reference is used; the other Project keeps the machine default")
    func projectOverride() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        try writeProject(directory, id: "beta", credential: "keychain:github-beta")
        let credentials = RecordingCredentialStore(seed: ["keychain:github": "ghp_default"])

        let transport = StubGitHubTransport.passing()
        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: credentials, gitHub: transport.validation(), checks: [.github]
        ).run())

        let alpha = findings.filter { $0.projectID == ProjectID(rawValue: "alpha") }
        let beta = findings.filter { $0.projectID == ProjectID(rawValue: "beta") }
        #expect(alpha.map(\.severity) == [.pass, .pass])
        #expect(beta.map(\.severity) == [.failure])
        #expect(beta[0].message.contains("keychain:github-beta"))
        #expect(!transport.paths.contains("/repos/acme/beta-backend"))
    }

    @Test("A Project's override token is the one sent to GitHub")
    func overrideTokenIsSent() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "beta", credential: "keychain:github-beta")
        let credentials = RecordingCredentialStore(
            seed: ["keychain:github": "ghp_default", "keychain:github-beta": "ghp_beta"]
        )
        let transport = StubGitHubTransport.passing()

        _ = await makeDoctor(
            directory: directory, credentials: credentials, gitHub: transport.validation(), checks: [.github]
        ).run()

        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_beta" })
        #expect(!transport.requests.isEmpty)
    }

    @Test("Filtering to one Project keeps only its GitHub findings, and asks GitHub nothing for the other")
    func projectFilter() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        try writeProject(directory, id: "beta")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github],
            projectFilter: ProjectID(rawValue: "alpha")
        ).run())

        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.projectID == ProjectID(rawValue: "alpha") })
        #expect(!transport.paths.contains("/repos/acme/beta-backend"))
    }

    @Test("With no valid Project, the machine default is context: info when it resolves or is absent")
    func noProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let resolving = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())
        #expect(resolving.map(\.severity) == [.info])
        #expect(resolving[0].projectID == nil)
        #expect(resolving[0].message.contains("No Project uses it yet"))

        let absent = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(),
            gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())
        #expect(absent.map(\.severity) == [.info])
        #expect(absent[0].message.contains("keychain:github"))

        let rejected = gitHubFindings(await makeDoctor(
            directory: directory,
            gitHub: StubGitHubTransport.passing(routes: ["/user": .unauthorized]).validation(), checks: [.github]
        ).run())
        #expect(rejected.map(\.severity) == [.failure])
    }

    @Test("--json rows for GitHub findings carry their Project; other checks' rows do not")
    func jsonCarriesProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")

        let findings = await makeDoctor(
            directory: directory, gitHub: StubGitHubTransport.passing().validation(),
            checks: [.configuration, .github]
        ).run()
        let rows = try #require(DoctorFindingRow.decodeLastLine([DoctorCommand.encodeFindingsJSON(findings)]))

        let github = rows.filter { $0.check == "github" }
        #expect(github.count == 2)
        #expect(github.allSatisfy { $0.projects == ["alpha"] })
        let others = rows.filter { $0.check != "github" }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.projects == nil })
    }

    @Test("--check github runs only the GitHub check")
    func checkNameParses() throws {
        #expect(DoctorCheck(rawValue: "github") == .github)
        #expect(DoctorCheck.allCases.firstIndex(of: .github) == DoctorCheck.allCases.firstIndex(of: .linear)! + 1)
    }
}
