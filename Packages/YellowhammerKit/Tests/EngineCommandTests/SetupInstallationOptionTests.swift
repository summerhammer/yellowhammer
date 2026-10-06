import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let githubOnly = "[github]\ncredential = \"keychain:github\"\n"

private func entry(_ name: String, workspace: String, credential: String? = nil) -> String {
    """
    [board.linear.connections.\(name)]
    credential = "\(credential ?? "keychain:linear-\(name)")"
    workspace = "\(workspace)"
    yellowhammer_identity = "app-user-1"
    operator = "user-op"


    """
}

/// A registry of `main` (workspace-old) and `acme` (workspace-1), each with a stored token pair.
private let twoEntries = entry("main", workspace: "workspace-old") + entry("acme", workspace: "workspace-1")
    + githubOnly
private let seededCredentials = ["keychain:linear-main": "secret", "keychain:linear-acme": "secret"]

/// Records the credential each install asked a store for, and every installation the board was bound to.
private final class InstallRecorder: Sendable {
    private let asked = Mutex<[String]>([])
    private let bound = Mutex<[String]>([])
    private let throwaway = ThrowawayInstallationStores()

    var references: [String] { asked.withLock { $0 } }
    var boundNames: [String] { bound.withLock { $0 } }
    var store: LinearInstallationStore { throwaway.makeStore() }

    func provide(_ installation: LinearInstallation) -> LinearInstallationStore {
        asked.withLock { $0.append(installation.credential.rawValue) }
        return store
    }

    func bind(_ installation: LinearInstallation) {
        bound.withLock { $0.append(installation.name) }
    }
}

private func projectArguments(installation: String? = nil, project: String = "demo") -> [String] {
    makeArguments(
        operatorID: "user-op", project: project, linearProject: "proj-1",
        specSource: "~/dev/demo-spec", repo: ["backend,backend,~/dev/demo-backend,swift test"],
        installation: installation
    )
}

private func demoBoard() async -> FakeProvisioningBoard {
    await makeBoard(
        project: BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "demo", teams: [engineeringTeam]),
        members: [operatorMember]
    )
}

private func projectFileExists(_ directory: URL) -> Bool {
    FileManager.default.fileExists(
        atPath: directory.appending(components: "projects", "demo.toml").path(percentEncoded: false)
    )
}

@Suite("Setup: --board-connection")
struct SetupInstallationOptionTests {
    @Test("The retired --installation option is rejected")
    func retiredInstallationOptionIsRejected() {
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--init", "--installation", "acme"])
        }
        #expect(throws: (any Error).self) {
            try SetupCommand.parse(["--install-linear", "--installation-name", "acme"])
        }
        #expect(throws: (any Error).self) {
            try ConfigCommand.parse(["remove-installation", "acme"])
        }
        #expect(throws: (any Error).self) {
            try RootCommand.parseAsRoot(["config", "operator", "--installation", "acme", "user-op"])
        }
    }

    @Test("--install-linear --board-connection main, approved for another workspace: nothing stored, file unchanged")
    func reconnectApprovedElsewhereIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let recorder = InstallRecorder()
        let events = Mutex<[LinearInstallEvent]>([])
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, events: "json", installation: "main"),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceID: "workspace-new", workspaceName: "Other"),
            linearInstallationStore: recorder.provide,
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(try Data(contentsOf: file) == before)
        #expect(recorder.references.isEmpty)
        #expect(try recorder.store.tokenStore.read() == nil)
        guard case .failed(let reason, let text)? = events.withLock({ $0 }).last else {
            Issue.record("expected .failed last")
            return
        }
        #expect(reason == .differentWorkspace)
        #expect(text.contains("not main's workspace"))
    }

    @Test("--install-linear --board-connection main, same workspace: tokens replaced, config.toml byte for byte")
    func reconnectSameWorkspaceKeepsFile() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let recorder = InstallRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, installation: "acme"),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(), linearInstallationStore: recorder.provide
        )

        try await setup.run()

        #expect(try Data(contentsOf: file) == before)
        #expect(recorder.references == ["keychain:linear-acme"])
        #expect(try recorder.store.tokenStore.read() != nil)
    }

    @Test("--install-linear --board-connection nope: refused listing the connected names; nothing opened or written")
    func unknownInstallationIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let opened = URLRecorder()
        let recorder = InstallRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, installation: "nope"),
            directory: directory, board: await makeBoard(), linearInstallSeams: happyPathSeams(opened: opened),
            linearInstallationStore: recorder.provide
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description.contains("nope") == true)
        #expect(error?.description.contains("main, acme") == true)
        #expect(opened.urls.isEmpty)
        #expect(recorder.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("--init --project --board-connection acme with two entries writes acme into the Project and binds acme")
    func initSelectsTheNamedInstallation() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let recorder = InstallRecorder()
        let setup = try makeSetup(
            arguments: projectArguments(installation: "acme"), directory: directory, board: await demoBoard(),
            credentials: RecordingCredentialStore(seed: seededCredentials), onBind: recorder.bind
        )

        try await setup.run()

        let text = try String(
            contentsOf: directory.url.appending(components: "projects", "demo.toml"), encoding: .utf8
        )
        #expect(text.contains("[board.linear]\nconnection = \"acme\""))
        #expect(!recorder.boundNames.isEmpty)
        #expect(Set(recorder.boundNames) == ["acme"])
    }

    @Test("--init --project without --board-connection, with entries: refused naming them; nothing written or called")
    func initWithoutInstallationIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let board = await demoBoard()
        let recorder = InstallRecorder()
        let setup = try makeSetup(
            arguments: projectArguments(), directory: directory, board: board,
            credentials: RecordingCredentialStore(seed: seededCredentials), onBind: recorder.bind
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description.contains("Project demo") == true)
        #expect(error?.description.contains("main, acme") == true)
        #expect(!projectFileExists(directory.url))
        #expect(recorder.boundNames.isEmpty)
        #expect(await board.creates == 0)
    }

    @Test("--init --project --board-connection nope: refused, no Project file")
    func initWithUnknownInstallationIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let recorder = InstallRecorder()
        let setup = try makeSetup(
            arguments: projectArguments(installation: "nope"), directory: directory, board: await demoBoard(),
            credentials: RecordingCredentialStore(seed: seededCredentials), onBind: recorder.bind
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description.contains("nope") == true)
        #expect(!projectFileExists(directory.url))
        #expect(recorder.boundNames.isEmpty)
    }

    @Test("--init without --project and without --board-connection runs no Linear step; with --operator it is refused")
    func initWithoutProjectSkipsTheLinearStep() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let recorder = InstallRecorder()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(), directory: directory, board: await makeBoard(),
            credentials: RecordingCredentialStore(seed: seededCredentials), output: output, onBind: recorder.bind
        )

        try await setup.run()

        #expect(recorder.boundNames.isEmpty)
        #expect(output.lines.contains("Setup complete."))
        #expect(try Data(contentsOf: file) == before)

        let refused = try makeSetup(
            arguments: makeArguments(operatorID: "user-op"), directory: directory, board: await makeBoard(),
            credentials: RecordingCredentialStore(seed: seededCredentials)
        )
        let error = await #expect(throws: SetupError.self) { try await refused.run() }
        #expect(error?.description.contains("--operator needs --board-connection") == true)
    }

    @Test("A named entry with no stored tokens, non-interactive: refused with the re-connect command")
    func missingTokensAreRefusedWithTheReconnectCommand() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let setup = try makeSetup(
            arguments: projectArguments(installation: "acme"), directory: directory, board: await demoBoard(),
            credentials: RecordingCredentialStore()
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description.contains("yh setup --install-linear --board-connection acme") == true)
        #expect(!projectFileExists(directory.url))
    }

    @Test("--print-choices --board-connection reads the named entry of several")
    func printChoicesReadsTheNamedEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let recorder = InstallRecorder()
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: ["--print-choices", "--board-connection", "main"], directory: directory,
            board: await makeBoard(members: [operatorMember]),
            credentials: RecordingCredentialStore(seed: seededCredentials), output: output, onBind: recorder.bind
        )

        try await setup.run()

        #expect(Set(recorder.boundNames) == ["main"])
        let choices = try JSONDecoder().decode(SetupChoices.self, from: Data(try #require(output.lines.last).utf8))
        #expect(choices.configuredOperator == "user-op")
    }

    @Test("--board-connection must not be empty")
    func emptyInstallationIsAValidationError() {
        #expect(throws: (any Error).self) {
            try SetupOptions(command: SetupCommand.parse(["--init", "--board-connection", " "]))
        }
    }

    @Test("--config --board-connection --operator sets that entry's operator; the identical second run is present")
    func configWithInstallationSetsOperator() async throws {
        let prepared = ConfigurationDirectory()
        try prepared.writeMachineFile("""
            [board.linear.connections.main]
            credential = "keychain:linear-main"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            \(githubOnly)
            """)
        let destination = ConfigurationDirectory()
        let credentials = RecordingCredentialStore(seed: seededCredentials)
        let arguments = makeArguments(
            initialize: false, config: prepared.path, operatorID: "user-op", installation: "main"
        )
        try await makeSetup(
            arguments: arguments, directory: destination, board: await makeBoard(members: [operatorMember]),
            credentials: credentials
        ).run()

        let machine = try MachineConfiguration.load(contentsOf: destination.url.appending(component: "config.toml"))
        #expect(machine.linearInstallation(named: "main")?.operatorIdentity == BoardObjectID(rawValue: "user-op"))

        let output = RecordingOutput()
        try await makeSetup(
            arguments: arguments, directory: destination, board: await makeBoard(members: [operatorMember]),
            credentials: credentials, output: output
        ).run()

        #expect(output.lines.contains { $0.hasPrefix("present") && $0.contains("config.toml") })
    }
}
