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
        "The interim installation name is the workspace name's lowercase ASCII words joined by dashes",
        arguments: [
            ("Acme", "acme"),
            ("Acme Corp, Inc.", "acme-corp-inc"),
            ("  --  ", "linear"),
            ("Ünïcode Team", "n-code-team")
        ]
    )
    func interimName(workspaceName: String, expected: String) {
        #expect(Setup.interimInstallationName(workspaceName: workspaceName) == expected)
    }

    @Test("An empty registry gets one entry named from the workspace; the Operator step fills its operator")
    func emptyRegistryAppendsEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let stores = RecordingStores()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceName: "Acme Corp"),
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

    @Test("--linear-credential names the credential of the entry the install creates")
    func linearCredentialOptionOverridesTheDefault() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let stores = RecordingStores()
        let arguments = makeArguments(initialize: false, operatorID: "user-op")
            + ["--linear-credential", "keychain:custom-linear"]
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(), linearInstallationStore: stores.provide
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.soleLinearInstallation?.credential.rawValue == "keychain:custom-linear")
        #expect(stores.references.map(\.rawValue) == ["keychain:custom-linear"])
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

    @Test("A different workspace is refused with the one-workspace text; config.toml is byte for byte unchanged")
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
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true), directory: directory,
            board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceID: "workspace-new", workspaceName: "Other"),
            linearInstallationStore: stores.provide
        )

        do {
            try await setup.run()
            Issue.record("expected the install to be refused")
        } catch let error as SetupError {
            #expect(error.description.contains("Linear workspace Other"))
            #expect(error.description.contains("connects one Linear workspace"))
            #expect(error.description.contains("yh project remove <id>"))
        }

        #expect(try Data(contentsOf: file) == before)
        #expect(stores.references.isEmpty)
        #expect(try stores.store.tokenStore.read() == nil)
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
