import Config
import Domain
@testable import EngineCommand
import Foundation
import Repositories
import Security
import Synchronization
import Testing

/// Every reader of the GitHub credential resolves through the Project's Code Hosting Connection: a refusal
/// (a name absent from the registry, or a `gh` CLI connection whose `gh` is not found) is raised before the
/// Keychain is read, a `gh` CLI connection holds no token, and a Keychain token connection reads exactly its
/// own reference.
@Suite("Code Hosting Connection readers")
struct CodeHostingReaderTests {
    /// A Keychain account no real run uses, deleted when the test ends.
    private struct ThrowawayItem {
        let reference = CredentialReference("keychain:yh-test-\(UUID().uuidString)")!
        let store = KeychainCredentialStore()

        func put(_ secret: String) throws {
            try store.store(secret, for: reference)
        }

        func remove() {
            try? store.delete(reference)
        }
    }

    private func configuration(
        selecting connection: String, connections: [CodeHostingConnection]
    ) throws -> (Configuration, ProjectConfiguration) {
        let machine = MachineConfiguration(codeHostingConnections: connections, cliAdapters: [], routingTable: [])
        let project = ProjectConfiguration(
            id: try #require(ProjectID(rawValue: "alpha")), name: "alpha", linearInstallationName: "acme",
            linearProject: "ALP", codeHostingConnectionName: connection, specSource: "~/spec",
            repos: [RepoDeclaration(name: "backend", path: "/repos/backend", role: .backend, check: .none)]
        )
        return (Configuration(machine: machine, projects: [project], invalidProjects: [], routingTables: [:]), project)
    }

    private func gitHubCLI(_ name: String) -> CodeHostingConnection {
        CodeHostingConnection(name: name, kind: .githubCLI(executable: nil))
    }

    private func keychain(_ name: String, _ item: ThrowawayItem) -> CodeHostingConnection {
        CodeHostingConnection(name: name, kind: .keychainToken(item.reference))
    }

    @Test("A Keychain token connection reads exactly its own reference")
    func keychainConnectionReadsItsReference() throws {
        let first = ThrowawayItem()
        let second = ThrowawayItem()
        defer {
            first.remove()
            second.remove()
        }
        try first.put("ghp_first")
        try second.put("ghp_second")
        let (configuration, project) = try configuration(
            selecting: "second", connections: [keychain("first", first), keychain("second", second)]
        )

        let token = try LandBinding.token(
            configuration: configuration, project: project, credentials: KeychainCredentialStore()
        )

        #expect(token == "ghp_second")
    }

    @Test("A gh CLI connection gives the land token seam no token, and the Keychain is never read")
    func landTokenSeamHoldsNoTokenForGitHubCLI() throws {
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])

        let token = try LandBinding.token(
            configuration: configuration, project: project, credentials: KeychainCredentialStore(),
            gitHubCLI: { _ in "/stub/gh" }
        )

        #expect(token == nil)
    }

    @Test("A gh CLI connection whose gh is not found is refused by the land token seam with the shared message")
    func landRefusesAMissingGitHubCLI() throws {
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])

        let error = #expect(throws: GitHubCLIExecutable.NotFound.self) {
            try LandBinding.token(
                configuration: configuration, project: project, credentials: KeychainCredentialStore(),
                gitHubCLI: { _ in throw GitHubCLIExecutable.NotFound() }
            )
        }

        #expect(error?.description == GitHubCLIExecutable.notFoundMessage)
        #expect(GitHubCLIExecutable.notFoundMessage.contains("`gh auth login`"))
    }

    @Test("A selection absent from the registry is refused by the land token seam")
    func landRefusesAbsentConnection() throws {
        let item = ThrowawayItem()
        let (configuration, project) = try configuration(
            selecting: "ghost", connections: [keychain("real", item)]
        )

        let error = #expect(throws: CodeHostingRefusal.self) {
            try LandBinding.token(
                configuration: configuration, project: project, credentials: KeychainCredentialStore()
            )
        }

        #expect(error == .notInRegistry(connection: "ghost"))
    }

    @Test("The land push credential for a gh connection is gh itself, found now, with its declared path first")
    func landPushCredentialForGitHubCLI() throws {
        let declared = CodeHostingConnection(name: "gh", kind: .githubCLI(executable: "/declared/gh"))
        let (configuration, project) = try configuration(selecting: "gh", connections: [declared])
        let seen = Mutex<[String?]>([])

        let credential = try LandBinding.pushCredential(
            configuration: configuration, project: project, credentials: KeychainCredentialStore(),
            gitHubCLI: { declared in
                seen.withLock { $0.append(declared) }
                return declared ?? "/path/gh"
            }
        )

        guard case .githubCLI(let executable) = credential else {
            Issue.record("expected the gh credential, got \(credential)")
            return
        }
        #expect(executable == "/declared/gh")
        #expect(seen.withLock { $0 } == ["/declared/gh"])
    }

    @Test("The mainline fetch credential for a gh connection is gh itself, found when the seam is called")
    func mainlineCredentialForGitHubCLI() throws {
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])
        let seen = Mutex(0)

        let seam = MainlineBinding.credential(
            configuration: configuration, project: project, credentials: KeychainCredentialStore(),
            gitHubCLI: { _ in
                seen.withLock { $0 += 1 }
                return "/stub/gh"
            }
        )
        #expect(seen.withLock { $0 } == 0)
        let credential = try seam()

        guard case .githubCLI(let executable)? = credential else {
            Issue.record("expected the gh credential, got \(String(describing: credential))")
            return
        }
        #expect(executable == "/stub/gh")
        #expect(seen.withLock { $0 } == 1)
    }

    @Test("The mainline fetch credential for a connection absent from the registry throws a refusal")
    func mainlineCredentialRefusesAbsentConnection() throws {
        let item = ThrowawayItem()
        let (configuration, project) = try configuration(selecting: "ghost", connections: [keychain("real", item)])

        let seam = MainlineBinding.credential(
            configuration: configuration, project: project, credentials: KeychainCredentialStore(),
            gitHubCLI: { _ in "/stub/gh" }
        )

        let error = #expect(throws: CodeHostingRefusal.self) { try seam() }
        #expect(error == .notInRegistry(connection: "ghost"))
    }

    @Test("A land push for a gh connection whose gh is missing throws the not-found message")
    func landPushCredentialWithoutGitHubCLI() throws {
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])

        #expect(throws: GitHubCLIExecutable.NotFound.self) {
            try LandBinding.pushCredential(
                configuration: configuration, project: project, credentials: KeychainCredentialStore(),
                gitHubCLI: { _ in throw GitHubCLIExecutable.NotFound() }
            )
        }
        _ = LandBinding.push(configuration: configuration, project: project)
    }

    @Test("yh project remove's push seam reports a refusal as credentials missing") // glossary:ignore GL001
    func projectRemoveRefusals() async throws {
        let repo = Repo(name: "backend", path: "/nonexistent/backend", role: .backend)
        let branch = FeatureBranch(name: "yh-demo")
        let cases: [(selection: String, detail: String)] = [
            ("gh", GitHubCLIExecutable.notFoundMessage),
            ("ghost", CodeHostingRefusal.notInRegistry(connection: "ghost").description)
        ]
        for (selection, detail) in cases {
            let (configuration, project) = try configuration(selecting: selection, connections: [gitHubCLI("gh")])

            let outcome = await ProjectRemoveCommand.push(
                configuration: configuration, project: project,
                gitHubCLI: { _ in throw GitHubCLIExecutable.NotFound() }
            )(branch, repo, .real)

            #expect(outcome == .credentialsMissingOrInsufficient(repository: "backend", detail: detail))
        }
    }

    @Test("The narrative scrub holds the selected connection's token, and nothing for a refusal")
    func scrubFollowsTheSelection() throws {
        let item = ThrowawayItem()
        defer { item.remove() }
        try item.put("ghp_scrub_me")

        let (held, heldProject) = try configuration(selecting: "mine", connections: [keychain("mine", item)])
        let scrub = NarrativeScrubBinding.source(mode: .real, configuration: held, project: heldProject)()
        #expect(scrub.credentials == ["ghp_scrub_me"])
        #expect(scrub.apply("token ghp_scrub_me leaked") == "token \(NarrativeScrub.marker) leaked")

        let (cli, cliProject) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])
        let cliScrub = NarrativeScrubBinding.source(mode: .real, configuration: cli, project: cliProject)()
        #expect(cliScrub.credentials.isEmpty)

        let (absent, absentProject) = try configuration(selecting: "ghost", connections: [keychain("mine", item)])
        #expect(
            NarrativeScrubBinding.source(mode: .real, configuration: absent, project: absentProject)()
                .credentials.isEmpty
        )
    }

    @Test("A rehearsal Night's scrub never reads the GitHub Keychain item")
    func rehearsalScrubReadsNothing() throws {
        let item = ThrowawayItem()
        defer { item.remove() }
        try item.put("ghp_not_for_rehearsal")
        let (configuration, project) = try configuration(selecting: "mine", connections: [keychain("mine", item)])

        let scrub = NarrativeScrubBinding.source(mode: .rehearsal, configuration: configuration, project: project)()

        #expect(scrub.credentials.isEmpty)
    }
}
