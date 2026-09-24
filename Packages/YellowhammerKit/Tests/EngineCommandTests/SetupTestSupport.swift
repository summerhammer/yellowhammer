import Config
import Domain
@testable import EngineCommand
import Foundation
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

/// Records every credential written, and answers reads from a seed or what was written.
final class RecordingCredentialStore: SetupCredentialStore {
    private let storage: Mutex<[String: String]>

    init(seed: [String: String] = [:]) {
        storage = Mutex(seed)
    }

    func secret(for reference: CredentialReference) -> String? {
        storage.withLock { $0[reference.rawValue] }
    }

    func store(_ secret: String, for reference: CredentialReference) throws {
        storage.withLock { $0[reference.rawValue] = secret }
    }
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
    linearClientID: String? = "yellowhammer-client-id",
    cli: [String] = [],
    route: String? = nil,
    fallback: [String] = [],
    operatorID: String? = nil,
    linearClientSecretStdin: Bool = false,
    project: String? = nil,
    projectName: String? = nil,
    linearProject: String? = nil,
    linearTeam: String? = nil,
    specSource: String? = nil,
    repo: [String] = [],
    installJobs: Bool = false,
    exportJobs: String? = nil,
    cron: Bool = false
) -> [String] {
    var arguments: [String] = []
    if initialize { arguments.append("--init") }
    if linearClientSecretStdin { arguments.append("--linear-client-secret-stdin") }
    if installJobs { arguments.append("--install-jobs") }
    if cron { arguments.append("--cron") }
    appendOption(&arguments, "--config", config)
    appendOption(&arguments, "--linear-client-id", linearClientID)
    appendOption(&arguments, "--route", route)
    appendOption(&arguments, "--operator", operatorID)
    appendOption(&arguments, "--project", project) // glossary:ignore GL001
    appendOption(&arguments, "--project-name", projectName) // glossary:ignore GL001
    appendOption(&arguments, "--linear-project", linearProject) // glossary:ignore GL001
    appendOption(&arguments, "--linear-team", linearTeam)
    appendOption(&arguments, "--spec-source", specSource)
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

    private let storage: Mutex<(calls: [Call], failingLabels: Set<String>)>

    init(failingLabels: Set<String> = []) {
        storage = Mutex((calls: [], failingLabels: failingLabels))
    }

    func bootout(label: String) async throws {
        storage.withLock { $0.calls.append(.bootout(label)) }
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

func makeSetup(
    arguments: [String],
    directory: borrowing ConfigurationDirectory,
    board: FakeProvisioningBoard,
    console: ScriptedConsole = ScriptedConsole(),
    credentials: RecordingCredentialStore = RecordingCredentialStore(seed: ["keychain:linear": "test-secret"]),
    output: RecordingOutput = RecordingOutput(),
    readStandardInputLine: @escaping () -> String? = { nil },
    notifications: NotificationRegistrationStub = NotificationRegistrationStub(.allowed),
    homeDirectory: URL = FileManager.default.temporaryDirectory
        .appending(component: "yh-home-\(UUID().uuidString)", directoryHint: .isDirectory),
    yhExecutablePath: String = "/usr/local/bin/yh",
    setupTimePATH: String? = "/usr/bin:/bin",
    fileExists: @escaping (String) -> Bool = { _ in false },
    launchAgents: any LaunchAgentControl = RecordingLaunchAgentControl()
) throws -> Setup {
    let command = try SetupCommand.parse(arguments)
    let options = try SetupOptions(command: command)
    return Setup(
        options: options,
        configurationDirectory: directory.url,
        output: { output.record($0) },
        console: console,
        credentials: credentials,
        readStandardInputLine: readStandardInputLine,
        bindProvisioning: { _, _, _ in board },
        registerNotifications: { await notifications.call() },
        homeDirectory: homeDirectory,
        yhExecutablePath: yhExecutablePath,
        setupTimePATH: setupTimePATH,
        fileExists: fileExists,
        launchAgents: launchAgents
    )
}
