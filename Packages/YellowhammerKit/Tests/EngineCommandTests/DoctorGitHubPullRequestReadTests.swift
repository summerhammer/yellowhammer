import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// `yh doctor` Check 5's pull request read check (shift-scheduling/diagnose-the-installation,
/// `#check-5-code-hosting-connections-github`; Merge Detection Ruling item 5): for each Project and each working
/// Repo, whether the selected Code Hosting Connection can read pull requests. Unable to read is a warning; a read
/// that cannot be verified is unverified. The push check's rows stay as they were.
@Suite("Doctor: Check 5 pull request read check")
struct DoctorGitHubPullRequestReadTests {
    private static let machineWithGitHubCLI = ConfigurationDirectory.machineFile + """


        [code_hosting.github.connections.gh]
        type = "gh"
        """

    /// A Project whose Repos are `~/dev/<id>-<name>`, so the stub's slug for one is `acme/<id>-<name>`.
    private static func writeProject(
        _ directory: borrowing ConfigurationDirectory, id: String,
        repos: [(name: String, role: String)] = [("backend", "backend")], connection: String = "github"
    ) throws {
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

    private static func gitHubFindings(
        _ directory: borrowing ConfigurationDirectory, gitHub: GitHubCredentialValidation,
        homeDirectory: URL? = nil
    ) async -> [DoctorFinding] {
        let doctor = if let homeDirectory {
            makeDoctor(directory: directory, homeDirectory: homeDirectory, gitHub: gitHub, checks: [.github])
        } else {
            makeDoctor(directory: directory, gitHub: gitHub, checks: [.github])
        }
        return await doctor.run().filter { $0.check == .github }
    }

    private static func readFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
        findings.filter { $0.subject.hasPrefix("pull request read ") }
    }

    private static func projectID(_ raw: String) throws -> ProjectID {
        try #require(ProjectID(rawValue: raw))
    }

    // MARK: Keychain token

    @Test("A Repo whose pull requests the token can read gets a pass line after its push line")
    func readable() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile")])
        let transport = StubGitHubTransport.passing()

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())

        #expect(findings.map(\.subject) == [
            "credential", "repo backend", "pull request read backend", "repo mobile", "pull request read mobile"
        ])
        let reads = Self.readFindings(findings)
        #expect(reads.map(\.severity) == [.pass, .pass])
        #expect(reads[0].message == "Project alpha (Code Hosting Connection github): " // glossary:ignore GL001
            + "Repo backend (acme/alpha-backend): the token can read pull requests.")
        #expect(reads[0].projectID == (try Self.projectID("alpha")))
        #expect(reads[0].codeHosting == DoctorCodeHostingScope(name: "github", projects: [try Self.projectID("alpha")]))
        #expect(transport.paths == [
            "/user", "/repos/acme/alpha-backend", "/repos/acme/alpha-backend/pulls",
            "/repos/acme/alpha-mobile", "/repos/acme/alpha-mobile/pulls"
        ])
    }

    @Test("The read check is a real pull request list read with the connection's token, never a scope inference")
    func readsWithTheToken() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha")
        // A fine-grained token: no scopes header, so nothing could be inferred from scopes.
        let transport = StubGitHubTransport.passing(routes: ["/user": .user(scopes: nil)])

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())

        #expect(Self.readFindings(findings).map(\.severity) == [.pass])
        let read = try #require(transport.requests.first { $0.url?.path().hasSuffix("/pulls") == true })
        #expect(read.httpMethod == "GET")
        #expect(read.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test-secret")
        let query = try #require(read.url?.query(percentEncoded: false))
        #expect(query.contains("state=all"))
        #expect(query.contains("head=acme:"))
    }

    @Test("A 403 or 404 on the read is a warning naming the Repo; its push line is unchanged")
    func cannotRead() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile")])
        let transport = StubGitHubTransport.passing(routes: [
            "/repos/acme/alpha-backend/pulls": StubGitHubTransport.Reply(
                403, body: #"{"message":"Resource not accessible by personal access token"}"#
            ),
            "/repos/acme/alpha-mobile/pulls": .notFound
        ])

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())

        #expect(findings.map(\.severity) == [.pass, .pass, .warning, .pass, .warning])
        #expect(findings[1].message.hasSuffix("Repo backend (acme/alpha-backend): the token can push."))
        let reads = Self.readFindings(findings)
        #expect(reads[0].message.contains("Repo backend (acme/alpha-backend): the token cannot read pull requests"))
        #expect(reads[0].message.contains("HTTP 403"))
        #expect(reads[1].message.contains("Repo mobile (acme/alpha-mobile): the token cannot read pull requests"))
        #expect(reads[1].message.contains("HTTP 404"))
        #expect(reads.allSatisfy { !$0.message.contains("unverified") })
    }

    @Test("A read GitHub could not answer is unverified: a warning that says so, not that it cannot read")
    func unverified() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha", repos: [("backend", "backend"), ("mobile", "mobile")])
        let transport = StubGitHubTransport.passing(routes: [
            "/repos/acme/alpha-backend/pulls": StubGitHubTransport.Reply(503),
            "/repos/acme/alpha-mobile/pulls": StubGitHubTransport.Reply(429)
        ])

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())

        let reads = Self.readFindings(findings)
        #expect(reads.map(\.severity) == [.warning, .warning])
        #expect(reads[0].message.contains(
            "Repo backend (acme/alpha-backend): whether the token can read pull requests is unverified"
        ))
        #expect(reads[0].message.contains(PullRequestReadFailure.Reason.unreachable.words))
        #expect(reads[1].message.contains(PullRequestReadFailure.Reason.rateLimited.words))
        #expect(reads.allSatisfy { !$0.message.contains("cannot read") })
        #expect(findings.filter { $0.subject.hasPrefix("repo ") }.allSatisfy { $0.severity == .pass })
    }

    @Test("A spec-role Repo, and a Repo with no GitHub origin, get no read check")
    func skipped() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(
            directory, id: "alpha", repos: [("backend", "backend"), ("web", "web"), ("spec", "spec")]
        )
        let transport = StubGitHubTransport.passing()
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-doctor-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let webPath = Doctor.expandTilde("~/dev/alpha-web", homeDirectory: home.path(percentEncoded: false))

        let findings = await Self.gitHubFindings(
            directory, gitHub: transport.validation(notGitHub: [webPath]), homeDirectory: home
        )

        #expect(findings.map(\.subject) == ["credential", "repo backend", "pull request read backend", "repo web"])
        #expect(!transport.paths.contains { $0.hasPrefix("/repos/acme/alpha-spec") })
        #expect(transport.paths.filter { $0.hasSuffix("/pulls") } == ["/repos/acme/alpha-backend/pulls"])
    }

    @Test("A refused connection reads no pull requests")
    func refusedConnection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/user": .unauthorized])

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())

        #expect(Self.readFindings(findings).isEmpty)
        #expect(!transport.paths.contains { $0.hasSuffix("/pulls") })
    }

    @Test("A read warning is not a refused-connection Health flag")
    func notAHealthFlag() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try Self.writeProject(directory, id: "alpha")
        let transport = StubGitHubTransport.passing(routes: ["/repos/acme/alpha-backend/pulls": .notFound])

        let findings = await Self.gitHubFindings(directory, gitHub: transport.validation())
        let rows = try #require(DoctorFindingRow.decodeLastLine([DoctorCommand.encodeFindingsJSON(findings)]))

        let read = try #require(rows.first { $0.subject == "pull request read backend" })
        #expect(read.severity == "warning")
        #expect(read.projects == ["alpha"])
        #expect(read.connection == "github")
        #expect(rows.allSatisfy { $0.subject != "credential" || $0.severity == "pass" })
    }

    // MARK: Who else checks the credential

    @Test("Only doctor reads pull requests: the shared credential report reads none unless asked")
    func onlyDoctorReads() async throws {
        let transport = StubGitHubTransport.passing()
        let validation = transport.validation()

        let report = await validation.report(
            reference: try #require(CredentialReference("keychain:github")),
            secret: .present("ghp_test-secret"), repos: [(name: "backend", path: "/dev/backend")]
        )

        #expect(report.repos.map(\.status) == [.ok])
        #expect(report.repos.allSatisfy { $0.pullRequestRead == nil })
        #expect(transport.paths == ["/user", "/repos/acme/backend"])
    }

    // MARK: gh CLI

    @Test("A gh connection whose account can read pull requests passes the read check")
    func gitHubCLIReadable() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithGitHubCLI)
        try Self.writeProject(directory, id: "alpha", connection: "gh")

        let findings = await Self.gitHubFindings(directory, gitHub: gh.validation())
            .filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.subject) == ["credential", "repo backend", "pull request read backend"])
        #expect(findings.map(\.severity) == [.pass, .pass, .pass])
        #expect(findings[2].message.hasSuffix(
            "Repo backend (acme/alpha-backend): gh's active account can read pull requests."
        ))
        #expect(gh.calls.contains { $0.contains("/repos/acme/alpha-backend/pulls?") })
    }

    @Test("A gh connection whose account cannot read pull requests is a warning; it can still push")
    func gitHubCLICannotRead() async throws {
        let gh = try StubGitHubCLI(canReadPullRequests: false)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.machineWithGitHubCLI)
        try Self.writeProject(directory, id: "alpha", connection: "gh")

        let findings = await Self.gitHubFindings(directory, gitHub: gh.validation())
            .filter { $0.codeHosting?.name == "gh" }

        #expect(findings.map(\.severity) == [.pass, .pass, .warning])
        #expect(findings[2].message.contains(
            "Repo backend (acme/alpha-backend): gh's active account cannot read pull requests"
        ))
    }
}
