import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let githubOnly = "[github]\ncredential = \"keychain:github\"\n"

/// A store provider that records the credential each install asked for, and hands back one throwaway
/// Keychain-backed store (deleted with the provider).
private final class RecordingStores: Sendable {
    private let asked = Mutex<[CredentialReference]>([])
    private let throwaway = ThrowawayInstallationStores()

    var references: [CredentialReference] { asked.withLock { $0 } }
    var store: LinearInstallationStore { throwaway.makeStore() }

    func provide(_ installation: LinearInstallation) -> LinearInstallationStore {
        asked.withLock { $0.append(installation.credential) }
        return store
    }
}

@Suite("Setup: the Linear install against the registry")
struct SetupInstallRegistryTests {
    @Test(
        "A new entry's name is the URL key, made a valid local name, and suffixed while taken",
        arguments: [
            ("acme", "acme"), ("Acme_Corp", "acme_corp"), ("Ünïcode Team", "n-code-team"),
            ("--  ", "linear"), ("acme-2", "acme-2")
        ]
    )
    func proposedName(urlKey: String, expected: String) throws {
        let machine = MachineConfiguration(
            gitHubCredential: try #require(CredentialReference("keychain:github")), cliAdapters: [], routingTable: []
        )
        #expect(Setup.proposedInstallationName(urlKey: urlKey, machine: machine) == expected)
    }

    @Test("An empty registry gets one entry named from the workspace; the Operator step fills its operator")
    func emptyRegistryAppendsEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let stores = RecordingStores()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: await makeBoard(members: [operatorMember]),
            console: ScriptedConsole(answers: ["", ""]), // Admin question -> install here; local name -> proposed
            linearInstallSeams: happyPathSeams(workspaceName: "Acme Corp", workspaceURLKey: "acme-corp"),
            linearInstallationStore: stores.provide
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations == [
            LinearInstallation(
                name: "acme-corp", credential: try #require(CredentialReference("keychain:linear-acme-corp")),
                workspace: BoardObjectID(rawValue: "workspace-1"), appUser: BoardObjectID(rawValue: "app-user-1"),
                operatorIdentity: BoardObjectID(rawValue: "user-op")
            )
        ])
        #expect(stores.references.map(\.rawValue) == ["keychain:linear-acme-corp"])
        #expect(try stores.store.tokenStore.read() != nil)
    }

    @Test("The same workspace re-connects the existing entry: its credential, name and operator stay")
    func sameWorkspaceReconnects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.main]
            credential = "keychain:existing-credential"
            workspace = "workspace-1"
            app_user = "app-user-old"
            operator = "user-op"

            \(githubOnly)
            """)
        let stores = RecordingStores()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true), directory: directory,
            board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceName: "Renamed Workspace"),
            linearInstallationStore: stores.provide
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations == [
            LinearInstallation(
                name: "main", credential: try #require(CredentialReference("keychain:existing-credential")),
                workspace: BoardObjectID(rawValue: "workspace-1"), appUser: BoardObjectID(rawValue: "app-user-1"),
                operatorIdentity: BoardObjectID(rawValue: "user-op")
            )
        ])
        #expect(stores.references.map(\.rawValue) == ["keychain:existing-credential"])
    }

    @Test("A targeted re-connect approved in another workspace stores nothing and leaves config.toml alone")
    func differentWorkspaceLeavesConfigAlone() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.main]
            credential = "keychain:existing-credential"
            workspace = "workspace-old"
            app_user = "app-user-old"

            \(githubOnly)
            """)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let stores = RecordingStores()
        let events = Mutex<[LinearInstallEvent]>([])
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, events: "json"), directory: directory,
            board: await makeBoard(members: [operatorMember]),
            linearInstallationStore: stores.provide,
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )
        var machine = try MachineConfiguration.load(contentsOf: file)
        let target = try #require(machine.linearInstallations.first)

        do {
            _ = try await setup.storeInstalled(
                tokens: approvedTokens, identity: approvedIdentity(workspaceID: "workspace-new", urlKey: "other"),
                target: target, machine: &machine
            )
            Issue.record("expected the re-connect to be refused")
        } catch let error as SetupError {
            #expect(error.description.contains("Other (other)"))
            #expect(error.description.contains("not main's workspace"))
        }

        #expect(try Data(contentsOf: file) == before)
        #expect(stores.references.isEmpty)
        #expect(try stores.store.tokenStore.read() == nil)
        #expect(machine.linearInstallations.count == 1)
        let recorded = events.withLock { $0 }
        guard case .failed(let reason, let text)? = recorded.last else {
            Issue.record("expected .failed, got \(String(describing: recorded.last))")
            return
        }
        #expect(reason == .differentWorkspace)
        #expect(text.contains("Other (other)"))
    }

    @Test("A new workspace next to an existing entry adds a second entry and leaves the first untouched")
    func newWorkspaceNextToExistingEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "main", workspace: "workspace-old") + githubOnly)
        let file = directory.url.appending(component: "config.toml")
        let firstBefore = try #require(try MachineConfiguration.load(contentsOf: file).linearInstallations.first)
        let stores = RecordingStores()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", installLinear: true),
            directory: directory,
            board: await makeBoard(members: [operatorMember]),
            console: ScriptedConsole(answers: ["", ""]), // Admin question -> install here; local name -> proposed
            linearInstallSeams: happyPathSeams(workspaceName: "Acme"), linearInstallationStore: stores.provide
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: file)
        #expect(machine.linearInstallations.map(\.name) == ["main", "acme"])
        #expect(machine.linearInstallations.first == firstBefore)
        #expect(machine.linearInstallations.last?.credential.rawValue == "keychain:linear-acme")
        #expect(stores.references.map(\.rawValue) == ["keychain:linear-acme"])
    }

    @Test("A URL key already used as another entry's name gets a -2 suffix")
    func urlKeyCollisionSuffixes() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "acme", workspace: "workspace-a") + githubOnly)
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", installLinear: true),
            directory: directory,
            board: await makeBoard(members: [operatorMember]),
            console: ScriptedConsole(answers: ["", ""]), // Admin question -> install here; local name -> proposed
            linearInstallSeams: happyPathSeams(workspaceID: "workspace-b", workspaceName: "Acme B")
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.map(\.name) == ["acme", "acme-2"])
        #expect(machine.linearInstallations.last?.credential.rawValue == "keychain:linear-acme-2")
    }

    @Test("Re-connecting the same workspace with the same app user leaves config.toml byte for byte")
    func sameWorkspaceSameAppUserKeepsFileBytes() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(
            existingEntry(name: "main", workspace: "workspace-1", appUser: "app-user-1") + githubOnly
        )
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let stores = RecordingStores()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true), directory: directory,
            board: await makeBoard(members: [operatorMember]), output: output,
            linearInstallSeams: happyPathSeams(), linearInstallationStore: stores.provide
        )

        try await setup.run()

        #expect(try Data(contentsOf: file) == before)
        #expect(try stores.store.tokenStore.read() != nil)
        #expect(stores.references.map(\.rawValue) == ["keychain:existing-credential"])
        #expect(output.lines.contains { $0.contains("Linear workspace Acme (as main)") })
    }

    @Test("Re-connecting the same workspace with a different app user changes only app_user")
    func sameWorkspaceNewAppUserChangesOnlyAppUser() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(
            existingEntry(name: "main", workspace: "workspace-1", appUser: "app-user-old") + githubOnly
        )
        let file = directory.url.appending(component: "config.toml")
        let before = try String(contentsOf: file, encoding: .utf8)
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true), directory: directory,
            board: await makeBoard(members: [operatorMember]), linearInstallSeams: happyPathSeams()
        )

        try await setup.run()

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == before.replacingOccurrences(of: "app-user-old", with: "app-user-1"))
    }

    @Test("--init writes the Project file with the run's installation")
    func initWritesProjectInstallation() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam]),
            members: [operatorMember]
        )
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"]
        )
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board,
            linearInstallSeams: happyPathSeams(workspaceName: "Acme")
        )

        try await setup.run()

        let text = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        let project = try ProjectConfiguration.parse(text, file: "demo.toml")
        #expect(project.linearInstallationName == "acme")
        #expect(text.contains("[board.linear]\ninstallation = \"acme\""))
        let configuration = try Configuration.load(directory: directory.url)
        #expect(configuration.invalidProjects.isEmpty)
    }
}

private let approvedTokens = LinearInstallFlow.InstalledTokens(
    accessToken: "at-1", refreshToken: "rt-1", expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
)

private func approvedIdentity(workspaceID: String, urlKey: String) -> LinearInstallFlow.InstalledIdentity {
    LinearInstallFlow.InstalledIdentity(
        appUserID: "app-user-1", workspaceID: workspaceID, workspaceName: "Other", workspaceURLKey: urlKey
    )
}

private func existingEntry(name: String, workspace: String, appUser: String = "app-user-old") -> String {
    """
    [board.linear.installations.\(name)]
    credential = "keychain:existing-credential"
    workspace = "\(workspace)"
    app_user = "\(appUser)"
    operator = "user-op"


    """
}
