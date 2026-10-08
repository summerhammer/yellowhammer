import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

/// `yh config` with a `gh` CLI Code Hosting Connection: it holds no token, so nothing is stored, and the
/// login it reports is whoever `gh` is signed in as at that moment.
@Suite("yh config, gh CLI Code Hosting Connection")
struct GitHubCLIConnectionTests {
    private static let withGitHubCLI = ConfigurationDirectory.machineFile + """


        [code_hosting.github.connections.gh]
        type = "gh"
        """

    private final class Deleter: InstallationCredentialDeleter {
        private let storage = Mutex<[String]>([])
        var references: [String] { storage.withLock { $0 } }
        func delete(_ reference: CredentialReference) throws { storage.withLock { $0.append(reference.rawValue) } }
    }

    private func manager(
        _ directory: borrowing ConfigurationDirectory, gitHub: GitHubCredentialValidation,
        store: RecordingCredentialStore = RecordingCredentialStore(), output: RecordingOutput = RecordingOutput(),
        deleter: Deleter = Deleter()
    ) -> CodeHostingConnectionManager {
        CodeHostingConnectionManager(
            directory: directory.url, output: output.record, credentials: store, credentialDeleter: deleter,
            gitHub: gitHub, importToken: { .unavailable("no gh") }, console: ScriptedConsole()
        )
    }

    private func machineText(_ directory: borrowing ConfigurationDirectory) throws -> String {
        try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
    }

    private func failure(_ body: () async throws -> Void) async -> SetupError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? SetupError
        }
    }

    private func connect(
        _ name: String, in directory: borrowing ConfigurationDirectory, gh: StubGitHubCLI
    ) async -> SetupError? {
        await failure { try await manager(directory, gitHub: gh.validation()).connectGitHubCLI(name: name) }
    }

    @Test("Connecting gh writes type = gh with no executable and names the live login; nothing is stored")
    func connectWritesAndNamesTheLogin() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore()
        let output = RecordingOutput()

        try await manager(directory, gitHub: gh.validation(), store: store, output: output)
            .connectGitHubCLI(name: "mac")

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.codeHostingConnection(named: "mac")?.kind == .githubCLI(executable: nil))
        #expect(!(try machineText(directory)).contains("executable"))
        #expect(store.storedSecrets.isEmpty)
        #expect(output.lines == ["Code Hosting Connection mac is ready: gh CLI, acting as GitHub user octocat."])
        #expect(gh.calls.allSatisfy { $0.hasPrefix("api -i") })
    }

    @Test("A missing gh refuses the connect with the shared message and writes nothing")
    func connectRefusedWithoutGitHubCLI() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let before = try machineText(directory)

        let error = await failure {
            try await manager(directory, gitHub: gh.validation(found: false)).connectGitHubCLI(name: "mac")
        }

        #expect(error?.message == GitHubCLIExecutable.notFoundMessage)
        #expect(try machineText(directory) == before)
        #expect(gh.calls.isEmpty)
    }

    @Test("A logged-out gh refuses the connect pointing at gh auth login, and writes nothing")
    func connectRefusedWhenLoggedOut() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let before = try machineText(directory)

        let error = await connect("mac", in: directory, gh: gh)

        let message = try #require(error?.message)
        #expect(message.contains("gh is not logged in to github.com; run `gh auth login`"))
        #expect(message.contains("never changes gh's login"))
        #expect(try machineText(directory) == before)
    }

    @Test("A gh that fails with stderr only is unreachable, naming its first stderr line, and writes nothing")
    func connectRefusedWhenGitHubCLIFails() async throws {
        let gh = try StubGitHubCLI(mode: .failing)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let before = try machineText(directory)

        let error = await connect("mac", in: directory, gh: gh)

        let message = try #require(error?.message)
        #expect(message.hasPrefix("gh could not reach GitHub: "))
        #expect(message.contains("gh: connection refused"))
        #expect(try machineText(directory) == before)
    }

    @Test("A Mac holds one gh connection: a second is refused under another name, and under the same name")
    func secondGitHubCLIRefused() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)
        let before = try machineText(directory)

        let other = await connect("other", in: directory, gh: gh)
        let same = await connect("gh", in: directory, gh: gh)

        #expect(other?.message == "this Mac already has a gh CLI connection, gh; a Mac holds at most one")
        #expect(same?.message == "Code Hosting Connection \"gh\" already exists")
        #expect(try machineText(directory) == before)
        #expect(gh.calls.isEmpty)
    }

    @Test("An invalid local name is refused before gh is asked anything")
    func invalidNameRefused() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let error = await connect("My Mac", in: directory, gh: gh)

        #expect(error?.message == "invalid Code Hosting Connection name \"My Mac\"")
        #expect(gh.calls.isEmpty)
    }

    @Test("replace-code-hosting-token on a gh connection is refused: it holds no token")
    func replaceRefused() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)
        let store = RecordingCredentialStore()

        let error = await failure {
            try await manager(directory, gitHub: gh.validation(), store: store)
                .connect(name: "gh", source: .githubCLI, replacing: true)
        }

        #expect(error?.message == "Code Hosting Connection gh is a gh CLI connection and holds no token")
        #expect(store.storedSecrets.isEmpty)
        #expect(gh.calls.isEmpty)
    }

    @Test("The registry report shows gh's live login, and a switched account shows on the next call")
    func reportFollowsTheActiveAccount() async throws {
        let gh = try StubGitHubCLI(login: "first-account")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)
        let output = RecordingOutput()
        let manager = manager(directory, gitHub: gh.validation(), output: output)

        let first = try await manager.report().connections.first { $0.name == "gh" }
        try gh.set(login: "second-account")
        let second = try await manager.report().connections.first { $0.name == "gh" }

        #expect(first?.type == .gh)
        #expect(first?.state == .ok)
        #expect(first?.identity == "first-account")
        #expect(second?.identity == "second-account")
        #expect(gh.calls.count == 2)
    }

    @Test("The registry report refuses a gh connection with the reason when gh is missing or logged out")
    func reportRefusesWhenUnusable() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)

        let loggedOut = try await manager(directory, gitHub: gh.validation()).report()
            .connections.first { $0.name == "gh" }
        let missing = try await manager(directory, gitHub: gh.validation(found: false)).report()
            .connections.first { $0.name == "gh" }

        #expect(loggedOut?.state == .refused)
        #expect(loggedOut?.reason?.contains("gh auth login") == true)
        #expect(loggedOut?.identity == nil)
        #expect(missing?.state == .refused)
        #expect(missing?.reason == GitHubCLIExecutable.notFoundMessage)
    }
}

/// The registry report's gh CLI offer, and the rest of the suite (split out to keep the type body short).
extension GitHubCLIConnectionTests {
    @Test("The report offers the gh CLI with its login when gh is found, logged in, and not yet connected")
    func offerAvailableWhenGitHubCLIResolves() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let report = try await manager(directory, gitHub: gh.validation()).report()

        #expect(report.gitHubCLI == .init(available: true, login: "octocat"))
    }

    @Test("The report withholds the gh CLI offer, pointing at gh auth login, when gh is logged out")
    func offerUnavailableWhenLoggedOut() async throws {
        let gh = try StubGitHubCLI(mode: .loggedOut)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let offer = try await manager(directory, gitHub: gh.validation()).report().gitHubCLI

        #expect(offer?.available == false)
        #expect(offer?.login == nil)
        #expect(offer?.reason?.contains("gh auth login") == true)
    }

    @Test("The report withholds the gh CLI offer with the shared not-found message when gh is missing")
    func offerUnavailableWhenNotFound() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()

        let offer = try await manager(directory, gitHub: gh.validation(found: false)).report().gitHubCLI

        #expect(offer == .init(available: false, reason: GitHubCLIExecutable.notFoundMessage))
    }

    @Test("The report withholds the gh CLI offer, with the connect refusal, once a gh connection exists")
    func offerUnavailableWhenRegistryHoldsOne() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)

        let report = try await manager(directory, gitHub: gh.validation()).report()

        #expect(report.gitHubCLI == .init(
            available: false,
            reason: "this Mac already has a gh CLI connection, gh; a Mac holds at most one"
        ))
        #expect(gh.calls.count == 1)
    }

    @Test("The gh CLI offer is reported even when no machine file exists")
    func offerPresentWithoutMachineFile() async throws {
        let gh = try StubGitHubCLI(login: "octocat")
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        let output = RecordingOutput()

        let report = try await manager(directory, gitHub: gh.validation(), output: output).report()

        #expect(report.connections.isEmpty)
        #expect(report.gitHubCLI == .init(available: true, login: "octocat"))
        #expect(output.lines == [report.encodeLine()])
    }

    @Test("The credential check of a gh connection reports the literal reference gh and each Repo")
    func checkCredentialUsesGitHubCLI() async throws {
        let gh = try StubGitHubCLI(canPush: false)
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)

        let report = try await manager(directory, gitHub: gh.validation())
            .checkCredential(connection: "gh", repoPaths: ["/repos/backend"])

        #expect(report.reference == "gh")
        #expect(report.state == .resolves)
        #expect(report.login == "octocat")
        #expect(report.repos.map(\.status) == [.noPushPermission])
        #expect(
            report.repos.first?.message == "Repo backend (acme/backend): gh's active account lacks push permission."
        )
    }

    @Test("Removing a gh connection deletes no Keychain item and never runs gh")
    func removalDeletesNothing() async throws {
        let gh = try StubGitHubCLI()
        defer { gh.remove() }
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(Self.withGitHubCLI)
        let deleter = Deleter()

        try manager(directory, gitHub: gh.validation(), deleter: deleter).remove(name: "gh")

        #expect(deleter.references.isEmpty)
        #expect(gh.calls.isEmpty)
        #expect(try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
            .codeHostingConnection(named: "gh") == nil)
    }

    @Test("connect-code-hosting takes exactly one of --token-stdin, --from-gh and --gh-cli")
    func sourceFlags() throws {
        _ = try ConfigConnectCodeHostingCommand.parse(["mac", "--gh-cli"])
        for arguments in [["mac"], ["mac", "--gh-cli", "--token-stdin"], ["mac", "--gh-cli", "--from-gh"]] {
            #expect(throws: (any Error).self) { try ConfigConnectCodeHostingCommand.parse(arguments) }
        }
        #expect(throws: (any Error).self) {
            try ConfigReplaceCodeHostingTokenCommand.parse(["mac", "--gh-cli"])
        }
    }
}
