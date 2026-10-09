import Config
import Domain
import Foundation
import Observation

/// The Code Hosting Connections registry, shared by Settings and the Setup wizard: one row per connection in
/// `config.toml`'s registry, with per row the Code Hosting identity `yh` read, a token replacement (a Keychain
/// token connection only) and a removal, and the ways to connect another. The app decides nothing (ADR-001):
/// every action is a `yh` invocation built in `Domain`, `config.toml` is only ever read here, no name is
/// validated and no removal is pre-computed — a refusal is `yh`'s own words, which name the Projects or the
/// undecodable file. The app never calls GitHub, reads the Keychain or runs `gh`.
///
/// The model never keeps a token: it travels as one line on `yh`'s standard input and is dropped when the
/// run starts. One action runs at a time. Owned by its window or wizard, so navigation neither
/// recreates it nor kills a running action.
@MainActor
@Observable
final class CodeHostingConnectionsModel {
    /// One Code Hosting Connection as `config.toml` holds it, plus the Projects that select it.
    struct Connection: Identifiable, Equatable {
        /// The local name, the registry key.
        let name: String
        let kind: CodeHostingConnectionKind
        /// Ids of the Projects whose `[code_hosting] connection` names this one, from the local files.
        let projects: [String]

        var id: String { name }
        var typeLabel: String { kind == .gh ? "gh CLI" : "Keychain token" }
    }

    /// The action that is running; one at a time.
    enum Action: Equatable {
        case connect
        case replace(String)
        case remove(String)
    }

    @ObservationIgnored var onConnected: (@MainActor (String) -> Void)?

    let directory: URL
    private(set) var connections: [Connection] = []
    /// Why `config.toml` could not be loaded, in the loader's own words.
    private(set) var loadFailure: String?
    /// What `yh config print-code-hosting-connections` said per connection; a connection it said nothing
    /// about is absent. Empty until the report is read.
    private(set) var live: [String: CodeHostingConnectionsReport.Connection] = [:]
    /// Whether connecting the gh CLI is offered; nil until the report is read.
    private(set) var gitHubCLIOffer: CodeHostingConnectionsReport.GitHubCLIOffer?
    /// `yh`'s lines when the report command exited non-zero or its last line did not decode.
    private(set) var reportFailure: [String]?
    private(set) var running: Action?
    /// `yh`'s lines after a connect it refused.
    private(set) var connectFailure: [String]?
    /// `yh`'s lines after the last connect it accepted.
    private(set) var connectedMessage: [String] = []
    /// `yh`'s lines after a token replacement it refused, per connection, shown verbatim in that row.
    private(set) var replaceFailures: [String: [String]] = [:]
    /// `yh`'s lines after the last token replacement it accepted, per connection.
    private(set) var replacedMessages: [String: [String]] = [:]
    /// `yh`'s lines after a removal it refused, per connection, shown verbatim in that row.
    private(set) var removalFailures: [String: [String]] = [:]
    /// `yh`'s lines after the last removal it accepted.
    private(set) var removalMessage: [String] = []

    @ObservationIgnored private let reportEngine = SetupEngine()
    @ObservationIgnored private let actionEngine = SetupEngine()
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var readGeneration = 0

    init(directory: URL = ConfigurationDirectory.current) {
        self.directory = directory
        load()
    }

    var isRunning: Bool { running != nil }

    // MARK: Rows

    /// The label a row shows: the Code Hosting identity `yh` read, else the local name.
    func label(for connection: Connection) -> String {
        live[connection.name]?.identity ?? connection.name
    }

    /// The local name the Keychain connect form starts with: the default one, unless a connection has it.
    var suggestedKeychainName: String {
        connections.contains { $0.name == CodeHostingConnection.defaultName } ? "" : CodeHostingConnection.defaultName
    }

    // MARK: Reading

    /// Reads `config.toml` and the Project files in `directory`. Never writes. A missing `config.toml` is
    /// an empty list; a Project naming an undeclared connection still loads.
    func load() {
        do {
            let machineFile = directory.appending(component: "config.toml", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: machineFile.path(percentEncoded: false)) else {
                loadFailure = nil
                apply([])
                return
            }
            let configuration = try Configuration.loadLeniently(directory: directory)
            loadFailure = nil
            apply(configuration.machine.codeHostingConnections.map { connection in
                Connection(
                    name: connection.name,
                    kind: Self.kind(of: connection),
                    projects: configuration.projects
                        .filter { $0.codeHostingConnectionName == connection.name }
                        .map(\.id.rawValue)
                )
            })
        } catch {
            loadFailure = error.description
            apply([])
        }
    }

    /// Reloads the registry without interfering with a running action.
    func reloadIfClean() {
        guard running == nil else { return }
        load()
    }

    /// A pane visit, Settings request or app activation asks for a fresh registry and live report.
    /// The model owns the task so navigating away cannot cancel it. Requests during an action are
    /// retained until it finishes; overlapping reads coalesce into one follow-up read.
    func requestRefresh() {
        Task { await refreshReport() }
    }

    /// Runs `yh config print-code-hosting-connections` once for the whole list. `yh` always reads the real
    /// configuration and Keychain, so while the app is pointed at another configuration (a UI test's
    /// fixture) it is not run unless a stub stands in for `yh`.
    func refreshReport() async {
        guard running == nil, !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            load()
            guard mayRunYH else { return }
            let generation = readGeneration
            var lines: [String] = []
            do {
                let status = try await reportEngine.run(arguments: SetupInvocation.codeHostingConnectionsArguments) {
                    lines.append($0)
                }
                guard generation == readGeneration, running == nil else {
                    if running != nil { refreshQueued = true }
                    continue
                }
                if status == 0, let report = CodeHostingConnectionsReport.decodeLastLine(lines) {
                    live = Dictionary(report.connections.map { ($0.name, $0) }) { _, last in last }
                    gitHubCLIOffer = report.gitHubCLI
                    reportFailure = nil
                } else {
                    live = [:]
                    gitHubCLIOffer = nil
                    reportFailure = lines.isEmpty ? ["yh exited \(status)."] : lines
                }
            } catch {
                guard generation == readGeneration, running == nil else {
                    if running != nil { refreshQueued = true }
                    continue
                }
                live = [:]
                gitHubCLIOffer = nil
                reportFailure = ["\(error)"]
            }
        } while refreshQueued && running == nil
    }

    // MARK: Connecting

    /// Connects the gh CLI under ``CodeHostingConnection/gitHubCLIDefaultName``; Yellowhammer holds no token.
    /// Returns whether `yh` accepted it.
    @discardableResult
    func connectGitHubCLI() async -> Bool {
        await connect(
            SetupInvocation.connectGitHubCLIArguments(connection: CodeHostingConnection.gitHubCLIDefaultName)
        )
    }

    /// Connects a Keychain token under `name`, `token` being one line on `yh`'s standard input.
    @discardableResult
    func connectKeychainToken(name: String, token: String) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let arguments = SetupInvocation.codeHostingTokenArguments(
            connection: localName(name), source: .standardInput, replace: false
        )
        return await connect(arguments, standardInput: trimmed + "\n")
    }

    /// Connects a Keychain token under `name`, copied once from the gh CLI.
    @discardableResult
    func connectKeychainTokenFromGitHubCLI(name: String) async -> Bool {
        await connect(
            SetupInvocation.codeHostingTokenArguments(connection: localName(name), source: .githubCLI, replace: false)
        )
    }

    // MARK: Replacing

    /// Replaces the Keychain connection `name`'s token with `token`. Returns whether `yh` accepted it.
    @discardableResult
    func replaceToken(of name: String, with token: String) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await replace(name, source: .standardInput, standardInput: trimmed + "\n")
    }

    /// Replaces the Keychain connection `name`'s token with a copy of the gh CLI's.
    @discardableResult
    func replaceTokenFromGitHubCLI(of name: String) async -> Bool {
        await replace(name, source: .githubCLI, standardInput: nil)
    }

    // MARK: Removing

    /// Runs `yh config remove-code-hosting-connection <name>`. Exit 0: reloads, refreshes and keeps `yh`'s
    /// lines as the list's success message. Otherwise `yh`'s lines are that row's refusal, verbatim.
    @discardableResult
    func remove(_ name: String) async -> Bool {
        await perform(
            .remove(name), arguments: ConfigInvocation.removeCodeHostingConnectionArguments(name: name),
            standardInput: nil,
            onFailure: { self.removalFailures[name] = $0 },
            onSuccess: { self.removalMessage = $0 }
        )
    }

    // MARK: Lifecycle

    /// Terminates every running `yh`: closing the Settings window is not an Act.
    func terminate() {
        readGeneration += 1
        refreshQueued = false
        reportEngine.terminate()
        actionEngine.terminate()
    }

    // MARK: Private

    /// `yh` reads the real configuration and Keychain, so while the app is pointed at another configuration
    /// (a UI test's fixture) it is not run unless a stub stands in for it.
    private var mayRunYH: Bool {
        !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed
    }

    /// The local name as typed, minus the whitespace around it; `yh` judges the rest.
    private func localName(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kind(of connection: CodeHostingConnection) -> CodeHostingConnectionKind {
        switch connection.kind {
        case .githubCLI: .gh
        case .keychainToken: .keychain
        }
    }

    private func connect(_ arguments: [String], standardInput: String? = nil) async -> Bool {
        let accepted = await perform(
            .connect, arguments: arguments, standardInput: standardInput,
            onFailure: { self.connectFailure = $0 },
            onSuccess: { self.connectedMessage = $0 }
        )
        if accepted, arguments.count > 2 { onConnected?(arguments[2]) }
        return accepted
    }

    private func replace(
        _ name: String, source: SetupInvocation.GitHubTokenSource, standardInput: String?
    ) async -> Bool {
        await perform(
            .replace(name),
            arguments: SetupInvocation.codeHostingTokenArguments(connection: name, source: source, replace: true),
            standardInput: standardInput,
            onFailure: { self.replaceFailures[name] = $0 },
            onSuccess: { self.replacedMessages[name] = $0 }
        )
    }

    /// Runs one action: clears the previous outcomes, runs `yh`, and on exit 0 hands its lines to
    /// `onSuccess`, reloads and refreshes the report; otherwise hands them, verbatim, to `onFailure`.
    private func perform(
        _ action: Action, arguments: [String], standardInput: String?,
        onFailure: ([String]) -> Void, onSuccess: ([String]) -> Void
    ) async -> Bool {
        guard mayRunYH, running == nil else { return false }
        running = action
        readGeneration += 1
        if isRefreshing { refreshQueued = true }
        clearOutcomes(of: action)
        var lines: [String] = []
        var accepted = false
        do {
            let status = try await actionEngine.run(arguments: arguments, standardInput: standardInput) {
                lines.append($0)
            }
            if status == 0 {
                onSuccess(lines)
                accepted = true
            } else {
                onFailure(lines.isEmpty ? ["yh exited \(status)."] : lines)
            }
        } catch {
            onFailure(["\(error)"])
        }
        running = nil
        // Keep success callbacks (including the wizard's connection selection) after the registry read.
        // A failed action must also honor refresh requests that arrived while it was running.
        if accepted { load() }
        if accepted || refreshQueued { await refreshReport() }
        return accepted
    }

    private func clearOutcomes(of action: Action) {
        switch action {
        case .connect:
            connectFailure = nil
            connectedMessage = []
        case .replace(let name):
            replaceFailures[name] = nil
            replacedMessages[name] = nil
        case .remove(let name):
            removalFailures[name] = nil
            removalMessage = []
        }
    }

    private func apply(_ rows: [Connection]) {
        connections = rows
        let names = Set(rows.map(\.name))
        live = live.filter { names.contains($0.key) }
        replaceFailures = replaceFailures.filter { names.contains($0.key) }
        replacedMessages = replacedMessages.filter { names.contains($0.key) }
        removalFailures = removalFailures.filter { names.contains($0.key) }
    }
}
