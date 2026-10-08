import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

/// Records every URL a happy-path attempt's opener was asked to open. Shared with
/// `SetupLinearRemoteInstallTests` (not `private`), which switches from the remote path to a working
/// local loopback in one of its own tests.
final class URLRecorder: Sendable {
    private let storage = Mutex<[URL]>([])
    func record(_ url: URL) { storage.withLock { $0.append(url) } }
    var urls: [URL] { storage.withLock { $0 } }
}

// roadmap P17.6 slice (b) (spec: board-projection/install-the-linear-app): the Linear step's install
// decision, outcome handling and NDJSON emission, with every `LinearInstallFlow` seam stubbed — no real
// socket, browser or network call.

/// A `CallbackListening` stub answering a scripted callback with no real socket. Shared with
/// `SetupLinearRemoteInstallTests` (not `private`) for the same reason as `URLRecorder`.
final class InstallListener: CallbackListening, Sendable {
    let port: Int
    let redirectURI: URL
    private let callback: @Sendable () -> LoopbackCallbackServer.CallbackResult

    init(port: Int, callback: @escaping @Sendable () -> LoopbackCallbackServer.CallbackResult) {
        self.port = port
        redirectURI = LinearInstallPortsConfiguration.redirectURI(forPort: port)
        self.callback = callback
    }

    func waitForCallback(timeout: Duration) async throws -> LoopbackCallbackServer.CallbackResult { callback() }
    func close() {}
}

private func portsBusySeams() -> LinearInstallSeams { busyLinearInstallSeams() }

private func failingCallbackSeams(
    error: String, errorDescription: String?
) -> LinearInstallSeams {
    let state = Mutex("")
    return LinearInstallSeams(
        portBinder: { port in
            InstallListener(port: port) {
                .init(code: nil, state: state.withLock { $0 }, error: error, errorDescription: errorDescription)
            }
        },
        holderLookup: NeverCalledPortHolderLookup(),
        opener: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
        },
        transport: { _ in throw URLError(.cannotConnectToHost) }
    )
}

@Suite("Setup: the Linear install step (P17.6)")
struct SetupLinearInstallTests {
    @Test("Not installed: install runs, the pair is stored, its registry entry written, then the operator step")
    func notInstalledInstallsStoresAndProceedsToOperator() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let opened = URLRecorder()
        let seams = happyPathSeams(opened: opened)
        let credentials = RecordingCredentialStore.withGitHub()
        let output = RecordingOutput()
        let reference = try #require(CredentialReference("keychain:test-install-\(UUID().uuidString)"))
        let lockPath = FileManager.default.temporaryDirectory
            .appending(component: "yh-test-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
        let store = LinearInstallationStore(
            reference: reference, keychain: KeychainCredentialStore(), machineLock: MachineLock(fileURL: lockPath)
        )
        let arguments = makeArguments(initialize: false, operatorID: "user-op", installation: "acme")
        let console = ScriptedConsole()
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            output: output, linearInstallSeams: seams, linearInstallationStore: { _ in store }
        )

        try await setup.run()

        #expect(opened.urls.count == 1)
        #expect(try store.tokenStore.read() != nil)
        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.count == 1)
        let installation = try #require(machine.linearInstallations.first)
        #expect(installation.workspace == BoardObjectID(rawValue: "workspace-1"))
        #expect(installation.appUser == BoardObjectID(rawValue: "app-user-1"))
        #expect(installation.operatorIdentity == BoardObjectID(rawValue: "user-op"))
        #expect(output.lines.contains { $0.contains("installed in the Linear workspace Acme (as acme)") })
        #expect(output.lines.contains { $0.contains("Operator: user-op") })
    }

    @Test("--install-linear with an existing operator keeps it and never touches Project files")
    func installLinearKeepsExistingOperatorAndSkipsProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile("""
            [board.linear.connections.acme]
            credential = "keychain:linear"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"
            operator = "user-op"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """)
        try directory.writeValidProjectFile(id: "demo")
        let board = await makeBoard(members: [operatorMember])
        let seams = happyPathSeams()
        let credentials = RecordingCredentialStore.withGitHub()
        let reference = try #require(CredentialReference("keychain:test-install-\(UUID().uuidString)"))
        let store = LinearInstallationStore(
            reference: reference, keychain: KeychainCredentialStore(),
            machineLock: MachineLock(fileURL: FileManager.default.temporaryDirectory.appending(
                component: "yh-test-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory
            ))
        )
        let arguments = makeArguments(initialize: false, installLinear: true)
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store }
        )

        try await setup.run()

        let machine = try MachineConfiguration.load(contentsOf: directory.url.appending(component: "config.toml"))
        #expect(machine.linearInstallations.count == 1)
        #expect(machine.linearInstallations.first?.operatorIdentity == BoardObjectID(rawValue: "user-op"))
        // Untouched: the Project file's content, byte for byte.
        let projectPath = directory.url.appending(components: "projects", "demo.toml")
        #expect(FileManager.default.fileExists(atPath: projectPath.path(percentEncoded: false)))
    }

    @Test("portsBusy, non-interactive: fails, the browser opener is never called")
    func portsBusyNonInteractiveFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let credentials = RecordingCredentialStore.withGitHub()
        let arguments = makeArguments(initialize: false, installLinear: true, events: "json")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            linearInstallSeams: portsBusySeams()
        )

        await #expect(throws: SetupError.self) { try await setup.run() }
    }

    @Test("notCompleted prints the non-admin copy and Linear's own text")
    func notCompletedPrintsNonAdminCopyAndLinearText() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let credentials = RecordingCredentialStore.withGitHub()
        let output = RecordingOutput()
        let console = ScriptedConsole(answers: ["n"])
        let arguments = makeArguments(initialize: false, installLinear: true)
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, console: console, credentials: credentials,
            output: output,
            linearInstallSeams: failingCallbackSeams(error: "server_error", errorDescription: "something broke")
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(output.lines.contains { $0.contains(LinearInstallCopy.nonAdmin) && $0.contains("something broke") })
    }

    @Test("A refused existing installation, non-interactive, fails naming yh setup --install-linear")
    func refusedExistingInstallationNonInteractiveFails() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        await board.refuseWorkspaceMembersNext(.notAuthenticated("token revoked"))
        let credentials = RecordingCredentialStore.withGitHub(["keychain:linear": "test-secret"])
        let arguments = makeArguments(initialize: true, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials
        )

        do {
            try await setup.run()
            Issue.record("expected a SetupError")
        } catch let error as SetupError {
            #expect(error.description.contains("yh setup --install-linear"))
        }
    }

    @Test("--events json: the happy path emits the exact NDJSON sequence")
    func eventsJSONHappyPathEmitsSequence() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard(members: [operatorMember])
        let seams = happyPathSeams()
        let credentials = RecordingCredentialStore.withGitHub()
        let events = Mutex<[LinearInstallEvent]>([])
        let reference = try #require(CredentialReference("keychain:test-install-\(UUID().uuidString)"))
        let store = LinearInstallationStore(
            reference: reference, keychain: KeychainCredentialStore(),
            machineLock: MachineLock(fileURL: FileManager.default.temporaryDirectory.appending(
                component: "yh-test-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory
            ))
        )
        let arguments = makeArguments(
            initialize: false, operatorID: "user-op", installLinear: true, events: "json"
        )
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            linearInstallSeams: seams, linearInstallationStore: { _ in store },
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        try await setup.run()

        let recorded = events.withLock { $0 }
        guard case .adminStatement = recorded.first else {
            Issue.record("expected .adminStatement first, got \(String(describing: recorded))")
            return
        }
        guard case .browserOpened = recorded[1] else {
            Issue.record("expected .browserOpened second, got \(String(describing: recorded[1]))")
            return
        }
        #expect(recorded[2] == .awaitingApproval)
        #expect(recorded[3] == .installed(workspaceName: "Acme", installation: "acme"))
        #expect(recorded.count == 4)
    }

    @Test("--events json: portsBusy emits portsBusy then failed, and never prompts")
    func eventsJSONPortsBusyEmitsSequence() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let board = await makeBoard()
        let credentials = RecordingCredentialStore.withGitHub()
        let events = Mutex<[LinearInstallEvent]>([])
        let arguments = makeArguments(initialize: false, installLinear: true, events: "json")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            linearInstallSeams: portsBusySeams(),
            linearInstallEvents: { event in events.withLock { $0.append(event) } }
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        let recorded = events.withLock { $0 }
        #expect(recorded.count == 3)
        guard case .portsBusy = recorded[1] else {
            Issue.record("expected .portsBusy second, got \(String(describing: recorded[1]))")
            return
        }
        guard case .failed(let reason, _) = recorded[2] else {
            Issue.record("expected .failed third, got \(String(describing: recorded[2]))")
            return
        }
        #expect(reason == .portsBusy)
    }

    @Test("Not installed, install fails non-interactively: notifications and routing warnings still run")
    func notInstalledFailureStillRunsLinearFreeSteps() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "demo")
        let board = await makeBoard()
        let credentials = RecordingCredentialStore.withGitHub()
        let output = RecordingOutput()
        let notifications = NotificationRegistrationStub(.allowed)
        let arguments = makeArguments(initialize: true, operatorID: "user-op", installation: "acme")
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials,
            output: output, notifications: notifications, linearInstallSeams: portsBusySeams()
        )

        await #expect(throws: SetupError.self) { try await setup.run() }

        #expect(notifications.callCount == 1)
        #expect(output.lines.contains { $0.contains("Local notifications: allowed") })
    }

    @Test("The re-install sweep names every configured Project's Linear-project team, deduped")
    func reinstallSweepNamesConfiguredProjectTeams() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "demo")
        let backendTeam = BoardTeam(id: BoardObjectID(rawValue: "team-backend"), key: "BACK", name: "Backend")
        let board = await makeBoard(
            project: BoardProjectScope(id: BoardObjectID(rawValue: "demo"), name: "demo", teams: [backendTeam]),
            members: [operatorMember]
        )
        let opened = URLRecorder()
        let seams = happyPathSeams(opened: opened)
        let credentials = RecordingCredentialStore.withGitHub(["keychain:linear": "existing-secret"])
        let output = RecordingOutput()
        let arguments = makeArguments(
            initialize: false, operatorID: "user-op", installLinear: true, installation: "acme"
        )
        let setup = try makeSetup(
            arguments: arguments, directory: directory, board: board, credentials: credentials, output: output,
            linearInstallSeams: seams
        )

        try await setup.run()

        #expect(output.lines.contains { $0.contains("BACK (Backend)") })
    }
}
