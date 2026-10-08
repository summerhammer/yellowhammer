import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

@Suite("yh config Code Hosting Connection commands")
struct CodeHostingConnectionCommandsTests {
    @Test("connect validates stdin token before storing and names the GitHub identity")
    func connectAcceptedToken() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["accepted-token"])
        let output = RecordingOutput()
        let manager = manager(
            directory: directory.url, store: store, transport: transport,
            input: "accepted-token", output: output
        )

        try await manager.connect(name: "company", source: .standardInput)

        #expect(store.storedSecrets.map(\.secret) == ["accepted-token"])
        let machineURL = directory.url.appending(component: "config.toml")
        let machine = try MachineConfiguration.load(contentsOf: machineURL)
        let reference = CodeHostingConnection.defaultCredentialReference(for: "company")
        #expect(machine.codeHostingConnection(named: "company")?.kind == .keychainToken(reference))
        #expect(output.lines.contains { $0.contains("octocat") })
        #expect(output.lines.allSatisfy { !$0.contains("accepted-token") })
    }

    @Test("a rejected token is never stored or added to the registry")
    func connectRejectedToken() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["some-other-token"])
        let manager = manager(directory: directory.url, store: store, transport: transport, input: "rejected-token")

        await #expect(throws: SetupError.self) {
            try await manager.connect(name: "company", source: .standardInput)
        }

        #expect(store.storedSecrets.isEmpty)
        #expect(try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
            .codeHostingConnection(named: "company") == nil)
        #expect(transport.bearerTokens == ["rejected-token"])
    }

    @Test("a rejected replacement leaves the current Keychain token untouched")
    func replacementRejectedToken() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore(seed: ["keychain:github": "old-token"])
        let transport = StubGitHubTransport.passing(acceptedTokens: ["old-token"])
        let manager = manager(directory: directory.url, store: store, transport: transport, input: "bad-token")

        await #expect(throws: SetupError.self) {
            try await manager.connect(name: "github", source: .standardInput, replacing: true)
        }

        #expect(store.secret(for: CodeHostingConnection.defaultCredentialReference(for: "github")) == "old-token")
        #expect(store.storedSecrets.isEmpty)
    }

    @Test("removal refuses a selected Project")
    func removalRefusesSelection() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let deleter = RecordingCodeHostingDeleter()
        let manager = manager(directory: directory.url, deleter: deleter)

        #expect(throws: SetupError.self) { try manager.remove(name: "github") }
        #expect(deleter.references.isEmpty)
    }

    @Test("removal refuses and names any undecodable Project file")
    func removalRefusesDecodeFailure() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "broken", "this is not valid TOML = [")
        let deleter = RecordingCodeHostingDeleter()
        let manager = manager(directory: directory.url, deleter: deleter)

        var message = ""
        do {
            try manager.remove(name: "github")
            Issue.record("expected removal refusal")
        } catch let error as SetupError {
            message = error.message
        }
        #expect(deleter.references.isEmpty)
        #expect(message.contains(managerOutputPath(directory.url, id: "broken")))
    }

    @Test("registry report lists every local connection, live identity, state, and selecting Project")
    func registryReport() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"

            [code_hosting.github.connections.gh]
            type = "gh"
            """)
        try directory.writeValidProjectFile(id: "alpha")
        let output = RecordingOutput()
        let commandManager = manager(
            directory: directory.url,
            store: RecordingCredentialStore(seed: ["keychain:github": "accepted-token"]),
            transport: StubGitHubTransport.passing(), output: output
        )

        let report = try await commandManager.report()

        #expect(report.connections.first(where: { $0.name == "github" })?.identity == "octocat")
        #expect(report.connections.first(where: { $0.name == "github" })?.projects == ["alpha"])
        #expect(report.connections.first(where: { $0.name == "gh" })?.state == .refused)
        #expect(!output.lines[0].contains("accepted-token"))
        #expect(CodeHostingConnectionsReport.decodeLastLine(output.lines) == report)
    }

    @Test("missing Keychain item reports refused without calling GitHub")
    func missingKeychainItem() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let transport = StubGitHubTransport.passing()
        let output = RecordingOutput()
        let manager = manager(directory: directory.url, transport: transport, output: output)

        let report = try await manager.checkCredential(connection: "github", repoPaths: [])

        #expect(report.state == .missing)
        #expect(transport.requests.isEmpty)
        #expect(!output.lines[0].contains("secret-value"))
    }

    @Test("rate-limited token validation refuses without storing the token")
    func rateLimitedToken() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore()
        let transport = StubGitHubTransport(routes: [
            "/user": .init(
                403, headers: ["X-RateLimit-Remaining": "0"],
                body: #"{"message":"API rate limit exceeded"}"#
            )
        ])
        let manager = manager(directory: directory.url, store: store, transport: transport, input: "token")

        await #expect(throws: SetupError.self) {
            try await manager.connect(name: "company", source: .standardInput)
        }

        #expect(store.storedSecrets.isEmpty)
        #expect(transport.bearerTokens == ["token"])
    }

    @Test("gh import is copied once and successful removal deletes only Yellowhammer's Keychain item")
    func importAndRemoval() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let store = RecordingCredentialStore()
        let transport = StubGitHubTransport.passing(acceptedTokens: ["imported-token"])
        let commandManager = manager(
            directory: directory.url, store: store, transport: transport,
            importer: { .token("imported-token") }
        )

        try await commandManager.connect(name: "company", source: .githubCLI)
        let deleter = RecordingCodeHostingDeleter()
        let removalManager = manager(directory: directory.url, store: store, deleter: deleter)
        try removalManager.remove(name: "company")

        #expect(store.storedSecrets.map(\.secret) == ["imported-token"])
        #expect(deleter.references == ["keychain:company"])
        #expect(try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
            .codeHostingConnection(named: "company") == nil)
    }

    @Test("connect and replace require exactly one token source")
    func tokenSourceOptions() throws {
        #expect(throws: (any Error).self) {
            try ConfigConnectCodeHostingCommand.parse(["company"])
        }
        #expect(throws: (any Error).self) {
            try ConfigConnectCodeHostingCommand.parse(["company", "--token-stdin", "--from-gh"])
        }
        #expect(throws: (any Error).self) {
            try ConfigReplaceCodeHostingTokenCommand.parse(["company"])
        }
        #expect(throws: (any Error).self) {
            try ConfigReplaceCodeHostingTokenCommand.parse(["company", "--token-stdin", "--from-gh"])
        }
        _ = try ConfigConnectCodeHostingCommand.parse(["company", "--token-stdin"])
        _ = try ConfigConnectCodeHostingCommand.parse(["company", "--from-gh"])
        _ = try ConfigReplaceCodeHostingTokenCommand.parse(["company", "--token-stdin"])
        _ = try ConfigReplaceCodeHostingTokenCommand.parse(["company", "--from-gh"])
    }

    @Test("connection removal does not accept force or orphan-project options")
    func removalHasNoForceOptions() {
        for option in ["--force", "--yes", "--orphan-projects"] {
            #expect(throws: (any Error).self) {
                try ConfigRemoveCodeHostingConnectionCommand.parse(["company", option])
            }
        }
    }

    @Test("credential check rejects empty connection and Repo paths")
    func credentialCheckRejectsEmptyValues() {
        #expect(throws: (any Error).self) {
            try ConfigCheckCodeHostingCredentialCommand.parse(["--connection", ""])
        }
        #expect(throws: (any Error).self) {
            try ConfigCheckCodeHostingCredentialCommand.parse(["--github-repo", ""])
        }
    }

    private func manager(
        directory: URL,
        store: RecordingCredentialStore = RecordingCredentialStore(),
        transport: StubGitHubTransport = .passing(),
        input: String? = nil,
        output: RecordingOutput = RecordingOutput(),
        deleter: RecordingCodeHostingDeleter = RecordingCodeHostingDeleter(),
        importer: @escaping @Sendable () async -> GitHubTokenImport = { .unavailable("no gh") }
    ) -> CodeHostingConnectionManager {
        CodeHostingConnectionManager(
            directory: directory, output: output.record, credentials: store, credentialDeleter: deleter,
            gitHub: transport.validation(), importToken: importer,
            console: OneLineConsole(input: input)
        )
    }
}

private struct OneLineConsole: SetupConsole {
    let input: String?
    func ask(_ prompt: String) -> String? { input }
    func askSecret(_ prompt: String) -> String? { input }
}

private final class RecordingCodeHostingDeleter: InstallationCredentialDeleter {
    private let storage = Synchronization.Mutex<[String]>([])
    var references: [String] { storage.withLock { $0 } }
    func delete(_ reference: CredentialReference) throws { storage.withLock { $0.append(reference.rawValue) } }
}

private func managerOutputPath(_ directory: URL, id: String) -> String {
    directory.appending(components: "projects", "\(id).toml").path(percentEncoded: false)
}
