import Config
import Domain
@testable import EngineCommand
import Foundation
import Security
import Synchronization

let engineeringTeam = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")
let operatorMember = BoardMember(
    id: BoardObjectID(rawValue: "user-op"), name: "operator", displayName: "Operator Person",
    isActive: true, isApp: false, isSelf: false
)
let secondCandidateMember = BoardMember(
    id: BoardObjectID(rawValue: "user-second"), name: "second", displayName: "Second Person",
    isActive: true, isApp: false, isSelf: false
)
let deactivatedMember = BoardMember(
    id: BoardObjectID(rawValue: "user-dead"), name: "gone", displayName: "Gone",
    isActive: false, isApp: false, isSelf: false
)
let appMember = BoardMember(
    id: BoardObjectID(rawValue: "user-bot"), name: "bot", displayName: "Bot",
    isActive: true, isApp: true, isSelf: false
)
let selfMember = BoardMember(
    id: BoardObjectID(rawValue: "user-self"), name: "yellowhammer", displayName: "Yellowhammer",
    isActive: true, isApp: false, isSelf: true
)

/// Answers `SetupCredentialStore` reads from a seed, and records what `store` was asked to keep.
final class RecordingCredentialStore: SetupCredentialStore {
    private let storage: Mutex<[String: String]>
    private let unreadable: Set<String>
    private let stores = Mutex<[StoredSecret]>([])

    /// `unreadable` names references whose item "exists but cannot be read" (a locked Keychain).
    init(seed: [String: String] = [:], unreadable: Set<String> = []) {
        storage = Mutex(seed)
        self.unreadable = unreadable
    }

    func presence(of reference: CredentialReference) -> CredentialPresence {
        if unreadable.contains(reference.rawValue) { return .unreadable("keychain is locked") }
        return secret(for: reference) != nil ? .present : .absent
    }

    func secret(for reference: CredentialReference) -> String? {
        storage.withLock { $0[reference.rawValue] }
    }

    func store(_ secret: String, for reference: CredentialReference) throws {
        storage.withLock { $0[reference.rawValue] = secret }
        stores.withLock { $0.append(StoredSecret(reference: reference.rawValue, secret: secret)) }
    }

    /// One `store` call.
    struct StoredSecret: Equatable {
        let reference: String
        let secret: String
    }

    /// Every `store` call, in order.
    var storedSecrets: [StoredSecret] { stores.withLock { $0 } }
}

/// Records every line `Setup` printed, in order.
final class RecordingOutput: Sendable {
    private let storage = Mutex<[String]>([])

    func record(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    var lines: [String] { storage.withLock { $0 } }
}

/// A fixed answer for `registerNotifications`, with a call count.
final class NotificationRegistrationStub: Sendable {
    private let storage: Mutex<(result: NotificationRegistration, calls: Int)>

    init(_ result: NotificationRegistration) {
        storage = Mutex((result, 0))
    }

    func call() async -> NotificationRegistration {
        storage.withLock { state in
            state.calls += 1
            return state.result
        }
    }

    var callCount: Int { storage.withLock { $0.calls } }
}

/// Builds `yh setup`'s argv, since `SetupCommand`'s `@Option`/`@Flag` storage is only valid once
/// decoded through `ArgumentParser`'s own parsing — not by constructing the type and assigning
/// properties directly.
func makeArguments(
    initialize: Bool = true,
    config: String? = nil,
    cli: [String] = [],
    route: String? = nil,
    fallback: [String] = [],
    operatorID: String? = nil,
    project: String? = nil,
    projectName: String? = nil,
    linearProject: String? = nil,
    linearTeam: String? = nil,
    specSource: String? = nil,
    nightStart: String? = nil,
    nightEnd: String? = nil,
    buildEveryMinutes: String? = nil,
    repo: [String] = [],
    installJobs: Bool = false,
    exportJobs: String? = nil,
    cron: Bool = false,
    installLinear: Bool = false,
    events: String? = nil,
    remote: Bool = false,
    installation: String? = nil,
    installationName: String? = nil
) -> [String] {
    var arguments: [String] = []
    if initialize { arguments.append("--init") }
    if installJobs { arguments.append("--install-jobs") }
    if cron { arguments.append("--cron") }
    if installLinear { arguments.append("--install-linear") }
    if remote { arguments.append("--remote") }
    appendOption(&arguments, "--board-connection", installation)
    appendOption(&arguments, "--board-connection-name", installationName)
    appendOption(&arguments, "--events", events)
    appendOption(&arguments, "--config", config)
    appendOption(&arguments, "--route", route)
    appendOption(&arguments, "--operator", operatorID)
    appendOption(&arguments, "--project", project) // glossary:ignore GL001
    appendOption(&arguments, "--project-name", projectName) // glossary:ignore GL001
    appendOption(&arguments, "--linear-project", linearProject) // glossary:ignore GL001
    appendOption(&arguments, "--linear-team", linearTeam)
    appendOption(&arguments, "--spec-source", specSource)
    appendOption(&arguments, "--night-start", nightStart)
    appendOption(&arguments, "--night-end", nightEnd)
    appendOption(&arguments, "--build-every-minutes", buildEveryMinutes)
    appendOption(&arguments, "--export-jobs", exportJobs)
    appendRepeated(&arguments, "--cli", cli)
    appendRepeated(&arguments, "--fallback", fallback)
    appendRepeated(&arguments, "--repo", repo)
    return arguments
}

private func appendOption(_ arguments: inout [String], _ flag: String, _ value: String?) {
    guard let value else { return }
    arguments += [flag, value]
}

private func appendRepeated(_ arguments: inout [String], _ flag: String, _ values: [String]) {
    for value in values { arguments += [flag, value] }
}

/// A recording fake for ``LaunchAgentControl``: records every call, in order, and can be scripted to
/// fail `enable`/`bootstrap` for a given label.
final class RecordingLaunchAgentControl: LaunchAgentControl, @unchecked Sendable {
    enum Call: Equatable {
        case bootout(String)
        case enable(String)
        case bootstrap(String)
    }

    private struct State {
        var calls: [Call] = []
        var failingLabels: Set<String>
        var loadedLabels: Set<String>
    }

    private let storage: Mutex<State>

    init(failingLabels: Set<String> = [], loadedLabels: Set<String> = []) {
        storage = Mutex(State(failingLabels: failingLabels, loadedLabels: loadedLabels))
    }

    func bootout(label: String) async throws {
        storage.withLock { $0.calls.append(.bootout(label)) }
    }

    func isLoaded(label: String) async -> Bool {
        storage.withLock { $0.loadedLabels.contains(label) }
    }

    func enable(label: String) async throws {
        storage.withLock { $0.calls.append(.enable(label)) }
        try failIfScripted(label: label)
    }

    func bootstrap(plistURL: URL) async throws {
        let label = plistURL.deletingPathExtension().lastPathComponent
        storage.withLock { $0.calls.append(.bootstrap(label)) }
        try failIfScripted(label: label)
    }

    private func failIfScripted(label: String) throws {
        let shouldFail = storage.withLock { $0.failingLabels.contains(label) }
        guard shouldFail else { return }
        throw LaunchctlError(description: "scripted failure for \(label)")
    }

    var calls: [Call] { storage.withLock { $0.calls } }
}

func makeBoard(
    project: BoardProjectScope? = nil, members: [BoardMember] = [operatorMember], teams: [BoardTeam] = [engineeringTeam]
) async -> FakeProvisioningBoard {
    let board = FakeProvisioningBoard(project: project)
    await board.setMembers(members)
    await board.setTeams(teams)
    return board
}

/// Never invoked by a test that keeps the default credential seed (an Installation already exists, so
/// `authorizeOrInstallLinear` never reaches the install path). Install-focused tests override every
/// `linearInstall*` parameter explicitly.
struct NeverCalledPortHolderLookup: PortHolderLookup {
    func holder(port: Int) async -> PortHolder? { nil }
}

/// The happy-path seams: binds the first port, echoes the flow's own `state` back, and exchanges
/// through a `StubHTTPTransport` scripted with a token grant and a confirm reply.
func happyPathSeams(
    workspaceID: String = "workspace-1", workspaceName: String = "Acme", workspaceURLKey: String = "acme",
    appUserID: String = "app-user-1",
    opened: URLRecorder = URLRecorder()
) -> LinearInstallSeams {
    let state = Mutex("")
    let transport = StubHTTPTransport([
        InstallFlowFixture.installationGrant(accessToken: "at-1", refreshToken: "rt-1"),
        InstallFlowFixture.json(
            #"{"data":{"viewer":{"id":"\#(appUserID)","name":"Yellowhammer"},"#
                + #""organization":{"id":"\#(workspaceID)","name":"\#(workspaceName)","#
                    + #""urlKey":"\#(workspaceURLKey)"}}}"#
        )
    ])
    return LinearInstallSeams(
        portBinder: { port in
            InstallListener(port: port) {
                .init(code: "code", state: state.withLock { $0 }, error: nil, errorDescription: nil)
            }
        },
        holderLookup: NeverCalledPortHolderLookup(),
        opener: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            state.withLock { $0 = items.first(where: { $0.name == "state" })?.value ?? "" }
            opened.record(url)
        },
        transport: transport.send
    )
}

/// Every loopback port busy: an install attempt fails before it opens a browser.
func busyLinearInstallSeams() -> LinearInstallSeams {
    LinearInstallSeams(
        portBinder: { port in throw LoopbackCallbackServer.BindError.busy(port: port) },
        holderLookup: NeverCalledPortHolderLookup(),
        opener: { _ in },
        transport: { _ in throw URLError(.cannotConnectToHost) }
    )
}

/// The default seams of ``makeSetup``: an install, if the run needs one, succeeds in workspace
/// "Acme" (`workspace-1`, Yellowhammer identity `app-user-1`).
func defaultLinearInstallSeams() -> LinearInstallSeams {
    happyPathSeams()
}

/// A Keychain-backed ``LinearInstallationStore`` under a unique throwaway reference, whose item is
/// deleted when the last copy of the provider is released.
final class ThrowawayInstallationStores: Sendable {
    let reference = CredentialReference("keychain:yh-test-\(UUID().uuidString)")!

    func store(_: LinearInstallation) -> LinearInstallationStore {
        makeStore()
    }

    func makeStore() -> LinearInstallationStore {
        LinearInstallationStore(
            reference: reference, keychain: KeychainCredentialStore(),
            machineLock: MachineLock(
                fileURL: FileManager.default.temporaryDirectory
                    .appending(component: "yh-test-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
            )
        )
    }

    deinit {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainCredentialStore.service,
            kSecAttrAccount as String: String(reference.rawValue.dropFirst("keychain:".count))
        ]
        SecItemDelete(query as CFDictionary)
    }
}

func makeSetup(
    arguments: [String],
    directory: borrowing ConfigurationDirectory,
    board: FakeProvisioningBoard,
    console: ScriptedConsole = ScriptedConsole(),
    credentials: RecordingCredentialStore = RecordingCredentialStore(
        seed: ["keychain:linear": "test-secret", "keychain:linear-acme": "test-secret"]
    ),
    output: RecordingOutput = RecordingOutput(),
    notifications: NotificationRegistrationStub = NotificationRegistrationStub(.allowed),
    homeDirectory: URL = FileManager.default.temporaryDirectory
        .appending(component: "yh-home-\(UUID().uuidString)", directoryHint: .isDirectory),
    yhExecutablePath: String = "/usr/local/bin/yh",
    setupTimePATH: String? = "/usr/bin:/bin",
    fileExists: @escaping (String) -> Bool = { _ in false },
    launchAgents: any LaunchAgentControl = RecordingLaunchAgentControl(),
    linearInstallSeams: LinearInstallSeams = defaultLinearInstallSeams(),
    linearInstallationStore: @escaping (LinearInstallation) -> LinearInstallationStore =
        ThrowawayInstallationStores().store,
    linearInstallEvents: @escaping @Sendable (LinearInstallEvent) -> Void = { _ in },
    onBind: @escaping @Sendable (LinearInstallation) -> Void = { _ in },
    commandLineToolLink: CommandLineToolLink = CommandLineToolLink(),
    isTTY: @escaping () -> Bool = { isatty(STDIN_FILENO) != 0 },
    runSudo: @escaping (String) throws -> Int32 = Setup.defaultRunSudo
) throws -> Setup {
    let command = try SetupCommand.parse(arguments)
    let options = try SetupOptions(command: command)
    var setup = Setup(
        options: options,
        configurationDirectory: directory.url,
        output: { output.record($0) },
        console: console,
        credentials: credentials,
        bindProvisioning: { installation, _ in
            onBind(installation)
            return board
        },
        registerNotifications: { await notifications.call() },
        homeDirectory: homeDirectory,
        yhExecutablePath: yhExecutablePath,
        setupTimePATH: setupTimePATH,
        fileExists: fileExists,
        launchAgents: launchAgents,
        linearInstallSeams: linearInstallSeams,
        linearInstallationStore: linearInstallationStore,
        linearInstallEvents: linearInstallEvents
    )
    setup.commandLineToolLink = commandLineToolLink
    setup.isTTY = isTTY
    setup.runSudo = runSudo
    return setup
}
