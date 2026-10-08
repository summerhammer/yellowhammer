import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// Writes a Project whose Repos are `~/dev/<id>-<name>`, so the stub's slug for one is `acme/<id>-<name>`.
private func writeProject(
    _ directory: borrowing ConfigurationDirectory, id: String,
    repos: [(name: String, role: String)] = [("backend", "backend")], connection: String = "github"
) throws {
    // A Project declares exactly one specification source: a `spec` role Repo or a `spec_source`.
    let specSource = repos.contains { $0.role == "spec" } ? "" : "spec_source = \"~/Developer/\(id)-spec\"\n"
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
        code_hosting = { connection = "\(connection)" }
        \(specSource)\(declarations)
        """)
}

/// The default machine file plus a Keychain token connection called `beta` and a `gh` CLI one called `gh`.
private let machineWithMoreConnections = ConfigurationDirectory.machineFile + """


    [code_hosting.github.connections.beta]
    type = "keychain"
    credential = "keychain:github-beta"

    [code_hosting.github.connections.gh]
    type = "gh"
    """

private func gitHubFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
    findings.filter { $0.check == .github }
}

private func projectID(_ raw: String) -> ProjectID {
    guard let id = ProjectID(rawValue: raw) else {
        preconditionFailure("Invalid ProjectID rawValue: \(raw)")
    }
    return id
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
        #expect(findings[0].codeHosting?.name == "github")
        #expect(findings[0].codeHosting?.projects == [projectID("alpha")])
        #expect(findings[1].projectID == projectID("alpha"))
        #expect(findings[2].projectID == projectID("alpha"))
        #expect(findings[0].message.contains("octocat"))
        #expect(findings[0].message.hasPrefix(
            "Code Hosting Connection github (type \"keychain\"; login \"octocat\"; Projects alpha): "
        ))
        #expect(findings[1].message.contains("Repo backend (acme/alpha-backend)"))
        #expect(transport.paths == ["/user", "/repos/acme/alpha-backend", "/repos/acme/alpha-mobile"])
    }

    @Test("A missing Keychain item fails, naming the connection, Projects, and both repair paths")
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
        #expect(failure.codeHosting?.name == "github")
        #expect(failure.codeHosting?.projects == [projectID("alpha")])
        #expect(failure.message.contains("Code Hosting Connection github"))
        #expect(failure.message.contains("Projects alpha"))
        #expect(failure.message.contains("keychain:github"))
        #expect(failure.message.contains("Settings › Code Hosting"))
        #expect(failure.message.contains("yh config replace-code-hosting-token github --token-stdin"))
        #expect(transport.requests.isEmpty)
    }

    @Test("A Keychain item that cannot be read fails with both repair paths")
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
        #expect(findings[0].codeHosting?.name == "github")
        #expect(findings[0].codeHosting?.projects == [projectID("alpha")])
        #expect(findings[0].message.contains("could not be read"))
        #expect(findings[0].message.contains("Settings › Code Hosting"))
        #expect(findings[0].message.contains("yh config replace-code-hosting-token github --token-stdin"))
        #expect(transport.requests.isEmpty)
    }

    @Test("A rejected token names both repair paths, skips Repos, and never prints the token")
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
        #expect(findings[0].codeHosting?.name == "github")
        #expect(findings[0].codeHosting?.projects == [projectID("alpha")])
        #expect(findings[0].message.contains("rejected"))
        #expect(findings[0].message.contains("Settings › Code Hosting"))
        #expect(findings[0].message.contains("yh config replace-code-hosting-token github --token-stdin"))
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

    @Test("A Project's own Code Hosting Connection is used; the other Project keeps the first")
    func projectSelection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(machineWithMoreConnections)
        try writeProject(directory, id: "alpha")
        try writeProject(directory, id: "beta", connection: "beta")
        let credentials = RecordingCredentialStore(seed: ["keychain:github": "ghp_default"])

        let transport = StubGitHubTransport.passing()
        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: credentials, gitHub: transport.validation(), checks: [.github]
        ).run())

        let github = findings.filter { $0.codeHosting?.name == "github" }
        let beta = findings.filter { $0.codeHosting?.name == "beta" }
        #expect(github.map(\.severity) == [.pass, .pass])
        #expect(beta.map(\.severity) == [.failure])
        #expect(beta[0].message.hasPrefix("Code Hosting Connection beta (type \"keychain\"; Projects beta): "))
        #expect(beta[0].message.contains("Settings › Code Hosting"))
        #expect(beta[0].message.contains("yh config replace-code-hosting-token beta --token-stdin"))
        #expect(!transport.paths.contains("/repos/acme/beta-backend"))
    }

    @Test("A Project's connection's token is the one sent to GitHub")
    func selectedTokenIsSent() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(machineWithMoreConnections)
        try writeProject(directory, id: "beta", connection: "beta")
        let credentials = RecordingCredentialStore(
            seed: ["keychain:github": "ghp_default", "keychain:github-beta": "ghp_beta"]
        )
        let transport = StubGitHubTransport.passing()

        _ = await makeDoctor(
            directory: directory, credentials: credentials, gitHub: transport.validation(), checks: [.github]
        ).run()

        let betaRequests = transport.requests.filter {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_beta"
        }
        #expect(!betaRequests.isEmpty)
        #expect(transport.paths.contains("/repos/acme/beta-backend"))
        #expect(transport.requests.contains {
            $0.url?.path == "/repos/acme/beta-backend"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_beta"
        })
    }

    @Test("A Project selecting a gh CLI connection fails, naming the connection, and asks GitHub nothing")
    func githubCLIConnectionFails() async throws {
        let directory = ConfigurationDirectory()
        let machine = """
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.gh]
            type = "gh"
            """
        try directory.writeMachineFile(machine)
        try writeProject(directory, id: "alpha", connection: "gh")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        let gh = try #require(findings.first { $0.codeHosting?.name == "gh" })
        #expect(gh.severity == .failure)
        #expect(gh.subject == "credential")
        #expect(gh.codeHosting?.projects == [projectID("alpha")])
        #expect(gh.message.hasPrefix("Code Hosting Connection gh (type \"gh\"; Projects alpha): "))
        #expect(gh.message.contains("gh CLI"))
        #expect(gh.message.contains("Settings › Code Hosting"))
        #expect(gh.message.contains("cannot use yet"))
        #expect(transport.requests.isEmpty)
    }

    @Test("A Project naming a connection the registry lacks fails on its own row, naming both fixes")
    func undeclaredConnectionFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha")
        try writeProject(directory, id: "stray", connection: "ghost")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        let stray = try #require(findings.first { $0.projectID == projectID("stray") })
        #expect(stray.severity == .failure)
        #expect(stray.subject == "project") // glossary:ignore GL001
        #expect(stray.codeHosting?.name == "ghost")
        #expect(stray.codeHosting?.projects == [projectID("stray")])
        #expect(stray.message.contains("Code Hosting Connection ghost"))
        #expect(stray.message.contains("yh config connect-code-hosting ghost --token-stdin"))
        #expect(stray.message.contains("[code_hosting]"))
        #expect(findings.filter { $0.codeHosting?.name == "github" }.map(\.severity) == [.pass, .pass])
    }

    @Test("Filtering to one Project keeps only its findings, and asks GitHub nothing for sibling connections")
    func projectFilter() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(machineWithMoreConnections)
        try writeProject(directory, id: "alpha")
        try writeProject(directory, id: "beta", connection: "beta")
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(seed: ["keychain:github": "ghp_default"]),
            gitHub: transport.validation(), checks: [.github],
            projectFilter: projectID("alpha")
        ).run())

        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.codeHosting?.projects.contains(projectID("alpha")) == true })
        #expect(!transport.paths.contains("/repos/acme/beta-backend"))
    }

    @Test("With no valid Project, each connection is context: info when it resolves or is absent")
    func noProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let resolving = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())
        #expect(resolving.map(\.severity) == [.info])
        #expect(resolving[0].projectID == nil)
        #expect(resolving[0].message.contains("No Project uses it yet"))
        #expect(resolving[0].message.hasPrefix(
            "Code Hosting Connection github (type \"keychain\"; login \"octocat\"; no Projects): "
        ))

        let absent = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(),
            gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())
        #expect(absent.map(\.severity) == [.info])
        #expect(absent[0].message.contains("keychain:github"))
        #expect(absent[0].message.hasPrefix("Code Hosting Connection github (type \"keychain\"; no Projects): "))

        let rejected = gitHubFindings(await makeDoctor(
            directory: directory,
            gitHub: StubGitHubTransport.passing(routes: ["/user": .unauthorized]).validation(), checks: [.github]
        ).run())
        #expect(rejected.map(\.severity) == [.info])
        #expect(rejected[0].message.contains("No Project uses it yet"))
    }

    @Test("With no valid Project, every registry connection gets a row; a gh one is context, not a fault")
    func noProjectsListsEveryConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(machineWithMoreConnections)

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, credentials: RecordingCredentialStore(seed: ["keychain:github": "ghp_default"]),
            gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.info, .info, .info])
        #expect(findings[0].message.hasPrefix(
            "Code Hosting Connection github (type \"keychain\"; login \"octocat\"; no Projects): "
        ))
        #expect(findings[1].message.hasPrefix("Code Hosting Connection beta (type \"keychain\"; no Projects): "))
        #expect(findings[2].message.hasPrefix("Code Hosting Connection gh (type \"gh\"; no Projects): "))
        #expect(findings[2].message.contains("gh CLI"))
    }

    @Test("With an empty registry and no Project, one info says how to connect a Code Hosting Connection")
    func emptyRegistry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("")

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: StubGitHubTransport.passing().validation(), checks: [.github]
        ).run())

        #expect(findings.map(\.severity) == [.info])
        #expect(findings[0].message.contains("No Code Hosting Connection is connected"))
        #expect(findings[0].message.contains("yh config connect-code-hosting github --token-stdin"))
    }

    @Test("--json rows for GitHub findings carry their Project and connection; other checks' rows do not")
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
        #expect(github.allSatisfy { $0.connection == "github" })
        let others = rows.filter { $0.check != "github" }
        #expect(!others.isEmpty)
        #expect(others.allSatisfy { $0.projects == nil })
        #expect(others.allSatisfy { $0.connection == nil })
    }

    @Test("Multiple Projects selecting one connection share one connection row, followed by repo rows per Project")
    func multipleProjectsShareConnectionRow() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try writeProject(directory, id: "alpha", repos: [("backend", "backend")])
        try writeProject(directory, id: "beta", repos: [("backend", "backend")])
        let transport = StubGitHubTransport.passing()

        let findings = gitHubFindings(await makeDoctor(
            directory: directory, gitHub: transport.validation(), checks: [.github]
        ).run())

        #expect(findings.count == 3)
        #expect(findings.map(\.subject) == ["credential", "repo backend", "repo backend"])
        #expect(findings[0].codeHosting?.name == "github")
        #expect(findings[0].codeHosting?.projects == [projectID("alpha"), projectID("beta")])
        #expect(findings[0].message.hasPrefix(
            "Code Hosting Connection github (type \"keychain\"; login \"octocat\"; Projects alpha, beta): "
        ))
        #expect(findings[1].projectID == projectID("alpha"))
        #expect(findings[2].projectID == projectID("beta"))

        let rows = try #require(DoctorFindingRow.decodeLastLine([DoctorCommand.encodeFindingsJSON(findings)]))
        let connectionRow = try #require(rows.first { $0.subject == "credential" })
        #expect(connectionRow.connection == "github")
        #expect(connectionRow.projects == ["alpha", "beta"])
    }

    @Test("--check github runs only the GitHub check")
    func checkNameParses() throws {
        #expect(DoctorCheck(rawValue: "github") == .github)
        #expect(DoctorCheck.allCases.firstIndex(of: .github) == DoctorCheck.allCases.firstIndex(of: .linear)! + 1)
    }
}
