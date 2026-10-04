import ArgumentParser
import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let githubOnly = "[github]\ncredential = \"keychain:github\"\n"

private func existingEntry(name: String, workspace: String) -> String {
    """
    [board.linear.installations.\(name)]
    credential = "keychain:existing-credential"
    workspace = "\(workspace)"
    app_user = "app-user-1"
    operator = "user-op"


    """
}

/// `--installation-name` (spec ruling OQ120): the Operator names a NEW Linear App Installation.
@Suite("Setup: --installation-name")
struct SetupInstallationNameTests {
    // MARK: Option level

    @Test("--installation-name cannot be combined with --installation")
    func conflictsWithInstallation() {
        #expect(throws: (any Error).self) {
            try SetupOptions(command: SetupCommand.parse([
                "--install-linear", "--installation", "main", "--installation-name", "work"
            ]))
        }
    }

    @Test("--installation-name cannot be combined with --print-choices") // glossary:ignore GL001
    func conflictsWithPrintChoices() {
        #expect(throws: (any Error).self) {
            let arguments = ["--print-choices", "--installation-name", "work"] // glossary:ignore GL001
            try SetupOptions(command: SetupCommand.parse(arguments))
        }
    }

    @Test("An empty --installation-name is a ValidationError")
    func emptyNameIsRejected() {
        #expect(throws: (any Error).self) {
            try SetupOptions(command: SetupCommand.parse(["--install-linear", "--installation-name", "  "]))
        }
    }

    @Test("--installation-name resolves to connecting a new workspace in every mode")
    func resolvesToConnectNew() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "main", workspace: "workspace-a") + githubOnly)
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        let argumentSets = [
            makeArguments(initialize: true, installationName: "work"),
            makeArguments(initialize: false, installationName: "work"),
            makeArguments(initialize: false, installLinear: true, installationName: "work")
        ]
        for arguments in argumentSets {
            let setup = try makeSetup(arguments: arguments, directory: directory, board: await makeBoard())
            guard case .connect(nil) = try setup.resolveLinearRequest(machine: machine) else {
                Issue.record("expected .connect(nil) for \(arguments)")
                continue
            }
        }
    }

    // MARK: A new workspace

    @Test("A given name creates the entry under that name, headless")
    func givenNameHeadless() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installLinear: true, events: "json",
                installationName: "work"
            ),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceName: "Acme", workspaceURLKey: "acme")
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.map(\.name) == ["work"])
        #expect(machine.linearInstallations.first?.credential.rawValue == "keychain:linear-work")
    }

    @Test("A given name answers the interactive prompt: no name question is asked")
    func givenNameInteractive() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let console = ScriptedConsole(answers: [""]) // Admin question -> install here
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, operatorID: "user-op", installLinear: true, installationName: "work"
            ),
            directory: directory, board: await makeBoard(members: [operatorMember]), console: console,
            linearInstallSeams: happyPathSeams(workspaceName: "Acme", workspaceURLKey: "acme")
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.map(\.name) == ["work"])
        #expect(machine.linearInstallations.first?.credential.rawValue == "keychain:linear-work")
        #expect(!console.prompts.contains { $0.contains("Local name") })
    }

    // MARK: Refusals, before the browser opens

    @Test("An invalid name is refused with nothing written and the flow never run")
    func invalidNameIsRefused() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let opened = URLRecorder()
        let events = Mutex<[LinearInstallEvent]>([])
        let console = ScriptedConsole()
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, installLinear: true, events: "json", installationName: "Bad Name"
            ),
            directory: directory, board: await makeBoard(), console: console,
            linearInstallSeams: happyPathSeams(opened: opened),
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(try Data(contentsOf: file) == before)
        #expect(opened.urls.isEmpty)
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        guard case .failed(let reason, let text)? = recorded.first else {
            Issue.record("expected .failed, got \(recorded)")
            return
        }
        #expect(reason == .invalidInstallationName)
        #expect(text.contains("Bad Name"))
    }

    @Test("An invalid name in a human run is refused before the admin question")
    func invalidNameHumanRun() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let opened = URLRecorder()
        let console = ScriptedConsole(answers: [""])
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, installationName: "_nope"),
            directory: directory, board: await makeBoard(), console: console,
            linearInstallSeams: happyPathSeams(opened: opened)
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(console.prompts.isEmpty)
        #expect(opened.urls.isEmpty)
    }

    @Test("A name used by another entry is refused naming that workspace, before the flow runs")
    func takenNameNamesTheOtherWorkspace() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "acme", workspace: "workspace-a") + githubOnly)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let opened = URLRecorder()
        let events = Mutex<[LinearInstallEvent]>([])
        let board = await makeBoard()
        await board.setWorkspace(BoardWorkspace(id: "workspace-a", name: "Acme Live", urlKey: "acme"))
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, installLinear: true, events: "json", installationName: "acme"
            ),
            directory: directory, board: board,
            linearInstallSeams: happyPathSeams(workspaceID: "workspace-b", opened: opened),
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(try Data(contentsOf: file) == before)
        #expect(opened.urls.isEmpty)
        let recorded = events.withLock { $0 }
        guard case .failed(let reason, let text)? = recorded.last, recorded.count == 1 else {
            Issue.record("expected one .failed, got \(recorded)")
            return
        }
        #expect(reason == .invalidInstallationName)
        #expect(text.contains("Acme Live"))
    }

    @Test("A taken name falls back to the workspace ID when the workspace name cannot be read")
    func takenNameFallsBackToWorkspaceID() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "acme", workspace: "workspace-a") + githubOnly)
        let board = await makeBoard()
        await board.failWorkspace(with: .notAuthenticated("revoked"))
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, installationName: "acme"),
            directory: directory, board: board
        )

        do {
            try await setup.run()
            Issue.record("expected the taken name to be refused")
        } catch let error as SetupError {
            #expect(error.description.contains("workspace-a"))
        }
    }

    // MARK: An approved workspace already in the registry

    @Test("A given name is discarded when Linear approves a connected workspace: re-connect, no rename")
    func givenNameDiscardedHeadless() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "main", workspace: "workspace-1") + githubOnly)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let events = Mutex<[LinearInstallEvent]>([])
        let setup = try makeSetup(
            arguments: makeArguments(
                initialize: false, installLinear: true, events: "json", installationName: "work"
            ),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(),
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        try await setup.run()

        #expect(try Data(contentsOf: file) == before)
        let machine = try MachineConfiguration.load(contentsOf: file)
        #expect(machine.linearInstallations.map(\.name) == ["main"])
        let recorded = events.withLock { $0 }
        let discardedIndex = recorded.firstIndex {
            if case .installationNameDiscarded = $0 { return true }
            return false
        }
        let installedIndex = recorded.firstIndex {
            if case .installed = $0 { return true }
            return false
        }
        let discarded = try #require(discardedIndex)
        #expect(discarded < (try #require(installedIndex)))
        guard case .installationNameDiscarded(let given, let installation, let text) = recorded[discarded] else {
            return
        }
        #expect(given == "work")
        #expect(installation == "main")
        #expect(text.contains("main"))
    }

    @Test("A discarded name is said in a human run, naming the existing local name")
    func givenNameDiscardedHuman() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(existingEntry(name: "main", workspace: "workspace-1") + githubOnly)
        let output = RecordingOutput()
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, installLinear: true, installationName: "work"),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            console: ScriptedConsole(answers: [""]), output: output, linearInstallSeams: happyPathSeams()
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.map(\.name) == ["main"])
        #expect(output.lines.contains { $0.contains("work was not used") && $0.contains("main") })
    }

    // MARK: Without the flag

    @Test("Without the flag a headless install still takes the proposal")
    func withoutFlagHeadlessTakesProposal() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(githubOnly)
        let setup = try makeSetup(
            arguments: makeArguments(initialize: false, operatorID: "user-op", installLinear: true, events: "json"),
            directory: directory, board: await makeBoard(members: [operatorMember]),
            linearInstallSeams: happyPathSeams(workspaceName: "Acme", workspaceURLKey: "acme")
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.map(\.name) == ["acme"])
    }
}
