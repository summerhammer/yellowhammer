import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let githubOnly = "[github]\ncredential = \"keychain:github\"\n"

private func entry(_ name: String, workspace: String) -> String {
    """
    [board.linear.installations.\(name)]
    credential = "keychain:linear-\(name)"
    workspace = "\(workspace)"
    app_user = "app-user-1"
    operator = "user-op"


    """
}

private let twoEntries = entry("main", workspace: "workspace-old") + entry("acme", workspace: "workspace-1")
    + githubOnly
private let seededCredentials = ["keychain:linear-main": "secret", "keychain:linear-acme": "secret"]

/// Records the credential of every installation a token store was asked for, and every installation bound.
private final class ChoiceRecorder: Sendable {
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

@Suite("yh setup, interactive: choosing and naming a Linear App Installation")
struct SetupInteractiveInstallationTests {
    private func machine(_ directory: borrowing ConfigurationDirectory) throws -> MachineConfiguration {
        try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
    }

    @Test("Choosing entry 2 of 2 authorizes that entry and runs no install flow")
    func choosingAnEntryUsesIt() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let recorder = ChoiceRecorder()
        let opened = URLRecorder()
        let output = RecordingOutput()
        let console = ScriptedConsole(answers: ["2", "n"]) // choice -> acme; Declare a Project now? -> no
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false), directory: directory,
            board: await makeBoard(members: [operatorMember]), console: console,
            credentials: RecordingCredentialStore(seed: seededCredentials), output: output,
            linearInstallSeams: happyPathSeams(opened: opened), linearInstallationStore: recorder.provide,
            onBind: recorder.bind
        )

        try await setup.run()

        #expect(Set(recorder.boundNames) == ["acme"])
        #expect(recorder.references.isEmpty)
        #expect(opened.urls.isEmpty)
        #expect(output.lines.contains("Linear workspaces:"))
        #expect(output.lines.contains { $0.contains("1) main — workspace workspace-old, Operator user-op") })
        #expect(output.lines.contains { $0.contains("3) Connect another Linear workspace") })
        #expect(console.prompts.first == "Choose [1-3]: ")
    }

    @Test("An entry without an Operator identity is listed as not chosen")
    func listingShowsOperatorNotChosen() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.installations.main]
            credential = "keychain:linear-main"
            workspace = "workspace-old"
            app_user = "app-user-1"

            \(githubOnly)
            """)
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false), directory: directory, board: await makeBoard(),
            console: ScriptedConsole(answers: []), output: output
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(output.lines.contains { $0.contains("1) main — workspace workspace-old, Operator not chosen") })
    }

    @Test("Choosing Connect another runs the install untargeted and adds a new entry")
    func connectAnotherAddsEntry() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let recorder = ChoiceRecorder()
        let console = ScriptedConsole(answers: [
            "3", // Connect another Linear workspace
            "", // Admin question -> install here
            "", // Local name -> proposed
            "n" // Declare a Project now?
        ])
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: await makeBoard(members: [operatorMember]), console: console,
            credentials: RecordingCredentialStore(seed: seededCredentials),
            linearInstallSeams: happyPathSeams(
                workspaceID: "workspace-new", workspaceName: "Gamma", workspaceURLKey: "gamma"
            ),
            linearInstallationStore: recorder.provide
        )

        try await setup.run()

        #expect(try machine(directory).linearInstallations.map(\.name) == ["main", "acme", "gamma"])
        #expect(recorder.references == ["keychain:linear-gamma"])
    }

    @Test("An out-of-range, empty or non-numeric choice re-asks")
    func badChoicesReask() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let console = ScriptedConsole(answers: ["9", "", "two", "1", "n"])
        let recorder = ChoiceRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false), directory: directory,
            board: await makeBoard(members: [operatorMember]), console: console,
            credentials: RecordingCredentialStore(seed: seededCredentials), onBind: recorder.bind
        )

        try await setup.run()

        #expect(console.prompts.prefix(4).allSatisfy { $0 == "Choose [1-3]: " })
        #expect(Set(recorder.boundNames) == ["main"])
    }

    @Test("EOF at the choice cancels and writes nothing")
    func eofAtChoiceCancels() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let recorder = ChoiceRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false), directory: directory, board: await makeBoard(),
            console: ScriptedConsole(answers: []), onBind: recorder.bind
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description == "setup was cancelled")
        #expect(try Data(contentsOf: file) == before)
        #expect(recorder.boundNames.isEmpty)
    }

    @Test("An empty registry goes straight to connecting, without a list")
    func emptyRegistryHasNoList() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let output = RecordingOutput()
        let console = ScriptedConsole(answers: ["", "", "n"]) // admin; local name; Declare a Project now?
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op"), directory: directory,
            board: await makeBoard(members: [operatorMember]), console: console, output: output
        )

        try await setup.run()

        #expect(!output.lines.contains { $0.contains("Linear workspaces:") })
        #expect(!console.prompts.contains { $0.hasPrefix("Choose [") })
        #expect(try machine(directory).linearInstallations.map(\.name) == ["acme"])
    }

    @Test("Connect another that ends in an already-registered workspace re-connects it, keeping its Operator")
    func connectAnotherToRegisteredWorkspaceReconnects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoEntries)
        let console = ScriptedConsole(answers: ["3", "", "n"]) // Connect another; admin; Declare a Project now?
        let recorder = ChoiceRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false), directory: directory,
            board: await makeBoard(members: [operatorMember]), console: console,
            credentials: RecordingCredentialStore(seed: seededCredentials),
            linearInstallSeams: happyPathSeams(workspaceID: "workspace-1"),
            linearInstallationStore: recorder.provide
        )

        try await setup.run()

        let loaded = try machine(directory)
        #expect(loaded.linearInstallations.map(\.name) == ["main", "acme"])
        #expect(loaded.linearInstallations.last?.operatorIdentity == BoardObjectID(rawValue: "user-op"))
        #expect(recorder.references == ["keychain:linear-acme"])
        #expect(!console.prompts.contains { $0.hasPrefix("Local name") })
        #expect(!console.prompts.contains { $0.hasPrefix("Operator identity") })
    }

    @Test("A typed local name becomes the entry name and derives the credential; bad and taken names re-ask")
    func typedLocalName() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(entry("main", workspace: "workspace-old") + githubOnly)
        let recorder = ChoiceRecorder()
        let output = RecordingOutput()
        let console = ScriptedConsole(answers: [
            "", // Admin question -> install here
            "Bad Name", // invalid
            "main", // taken
            " acme-main " // accepted, trimmed
        ])
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", installLinear: true),
            directory: directory, board: await makeBoard(members: [operatorMember]), console: console,
            output: output, linearInstallationStore: recorder.provide
        )

        try await setup.run()

        let loaded = try machine(directory)
        #expect(loaded.linearInstallations.map(\.name) == ["main", "acme-main"])
        #expect(loaded.linearInstallations.last?.credential.rawValue == "keychain:linear-acme-main")
        #expect(recorder.references == ["keychain:linear-acme-main"])
        #expect(try recorder.store.tokenStore.read() != nil)
        #expect(output.lines.contains { $0.contains("Bad Name is not a valid local name") })
        #expect(output.lines.contains { $0.contains("main is already used") })
        #expect(console.prompts.filter { $0.hasPrefix("Local name for this Linear workspace [acme]") }.count == 3)
    }

    @Test("EOF at the local-name prompt stores no tokens and leaves config.toml unchanged")
    func eofAtLocalNameStoresNothing() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(entry("main", workspace: "workspace-old") + githubOnly)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let recorder = ChoiceRecorder()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", installLinear: true),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            console: ScriptedConsole(answers: [""]), // Admin question -> install here; then EOF
            linearInstallationStore: recorder.provide
        )

        let error = await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(error?.description == "setup was cancelled")
        #expect(try Data(contentsOf: file) == before)
        #expect(recorder.references.isEmpty)
        #expect(try recorder.store.tokenStore.read() == nil)
    }

    @Test("--install-linear --events json adds a new entry without asking for a name")
    func eventsJSONDoesNotAskForAName() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(entry("main", workspace: "workspace-old") + githubOnly)
        let console = ScriptedConsole(answers: [])
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installLinear: true, events: "json"
            ),
            directory: directory, board: await makeBoard(members: [operatorMember]), console: console
        )

        try await setup.run()

        #expect(console.prompts.isEmpty)
        #expect(try machine(directory).linearInstallations.map(\.name) == ["main", "acme"])
    }
}
