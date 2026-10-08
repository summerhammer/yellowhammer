import Config
import Domain
@testable import EngineCommand
import Foundation
import Repositories
import Security
import Testing

/// Every reader of the GitHub credential resolves through the Project's Code Hosting Connection: a refusal
/// (a `gh` CLI connection, or a name absent from the registry) is raised before the Keychain is read, and a
/// Keychain token connection reads exactly its own reference.
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
        CodeHostingConnection(name: name, kind: .githubCLI)
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

    @Test("A gh CLI connection is refused by the land token seam, and the Keychain is never read")
    func landRefusesGitHubCLI() throws {
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])

        let error = #expect(throws: CodeHostingRefusal.self) {
            try LandBinding.token(
                configuration: configuration, project: project, credentials: KeychainCredentialStore()
            )
        }

        #expect(error == .githubCLINotSupported(connection: "gh"))
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

    @Test("The land push seam turns the refusal into the credentials-missing outcome carrying its description")
    func landPushSeamCarriesTheRefusal() throws {
        // The push seam is FeatureBranchLanePush, which reports a thrown token error as
        // `credentialsMissingOrInsufficient(detail: "...could not be resolved: \(error)")`; the detail is the
        // refusal's own description because ``CodeHostingRefusal`` prints as its sentence.
        let refusal = CodeHostingRefusal.githubCLINotSupported(connection: "gh")
        #expect("\(refusal)" == refusal.description)
        let (configuration, project) = try configuration(selecting: "gh", connections: [gitHubCLI("gh")])
        _ = LandBinding.push(configuration: configuration, project: project)
    }

    @Test("yh project remove's push seam reports a refusal as credentials missing") // glossary:ignore GL001
    func projectRemoveRefusals() async throws {
        let repo = Repo(name: "backend", path: "/nonexistent/backend", role: .backend)
        let branch = FeatureBranch(name: "yh-demo")
        for (selection, expected) in [
            ("gh", CodeHostingRefusal.githubCLINotSupported(connection: "gh")),
            ("ghost", CodeHostingRefusal.notInRegistry(connection: "ghost"))
        ] {
            let (configuration, project) = try configuration(selecting: selection, connections: [gitHubCLI("gh")])

            let outcome = await ProjectRemoveCommand.push(configuration: configuration, project: project)(
                branch, repo, .real
            )

            #expect(outcome == .credentialsMissingOrInsufficient(repository: "backend", detail: expected.description))
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
