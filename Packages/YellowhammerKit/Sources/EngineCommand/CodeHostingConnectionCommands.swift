import ArgumentParser
import Config
import Domain
import Foundation

struct CodeHostingConnectionManager {
    let directory: URL
    let output: (String) -> Void
    let credentials: any SetupCredentialStore
    let credentialDeleter: any InstallationCredentialDeleter
    let gitHub: GitHubCredentialValidation
    let importToken: @Sendable () async -> GitHubTokenImport
    let console: any SetupConsole

    var machineURL: URL { directory.appending(component: "config.toml", directoryHint: .notDirectory) }

    func connect(name: String, source: GitHubCapture, replacing: Bool = false) async throws {
        let current = try load()
        let reference = try credentialReference(name: name, replacing: replacing, configuration: current)
        let token = try await readToken(from: source)
        let validation = await gitHub.report(
            reference: reference, secret: .present(token), repos: [], connectionName: name
        )
        guard validation.state == .resolves else { throw SetupError(validation.message, gitHub: true) }
        try store(token, for: reference, name: name, replacing: replacing, configuration: current)
        output("Code Hosting Connection \(name) is ready as GitHub user \(validation.login ?? "unknown").")
    }

    /// Connects the GitHub CLI itself under `name`: it holds no token, so nothing is read or stored in the
    /// Keychain. `gh` is resolved and asked who it is first, and the registry entry (`type = "gh"`, no
    /// `executable`, since resolution stays live through `PATH`) is written only when that resolves.
    func connectGitHubCLI(name: String) async throws {
        let current = try load()
        guard LinearInstallation.isValidLocalName(name) else {
            throw SetupError("invalid Code Hosting Connection name \"\(name)\"")
        }
        let connections = current?.machine.codeHostingConnections ?? []
        guard !connections.contains(where: { $0.name == name }) else {
            throw SetupError("Code Hosting Connection \"\(name)\" already exists")
        }
        if let existing = connections.first(where: { if case .githubCLI = $0.kind { true } else { false } }) {
            throw SetupError(
                "this Mac already has a gh CLI connection, \(existing.name); a Mac holds at most one"
            )
        }
        let validation = await gitHub.reportGitHubCLI(executable: nil, repos: [], connectionName: name)
        guard validation.state == .resolves else { throw SetupError(validation.message, gitHub: true) }
        do {
            try saveConnection(
                CodeHostingConnection(name: name, kind: .githubCLI(executable: nil)), configuration: current
            )
        } catch {
            throw SetupError("could not update the Code Hosting Connection registry: \(error)")
        }
        output(
            "Code Hosting Connection \(name) is ready: gh CLI, acting as GitHub user "
                + "\(validation.login ?? "unknown")."
        )
    }

    private func credentialReference(
        name: String, replacing: Bool, configuration: Configuration?
    ) throws -> CredentialReference {
        if !replacing, !LinearInstallation.isValidLocalName(name) {
            throw SetupError("invalid Code Hosting Connection name \"\(name)\"")
        }
        let existing = configuration?.machine.codeHostingConnection(named: name)
        if replacing {
            guard let existing else { throw SetupError("no Code Hosting Connection is named \"\(name)\"") }
            guard case .keychainToken(let reference) = existing.kind else {
                throw SetupError("Code Hosting Connection \(name) is a gh CLI connection and holds no token")
            }
            return reference
        }
        guard existing == nil else {
            throw SetupError("Code Hosting Connection \"\(name)\" already exists; use replace-code-hosting-token")
        }
        let reference = CodeHostingConnection.defaultCredentialReference(for: name)
        let isShared = configuration?.machine.codeHostingConnections.contains { connection in
            guard connection.name != name, case .keychainToken(let other) = connection.kind else { return false }
            return other == reference
        } ?? false
        guard !isShared else {
            throw SetupError("the Keychain item for \(reference.rawValue) is shared by another Code Hosting Connection")
        }
        return reference
    }

    private func readToken(from source: GitHubCapture) async throws -> String {
        switch source {
        case .standardInput:
            guard let line = console.ask(""), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SetupError("no GitHub token was read from standard input")
            }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        case .githubCLI:
            switch await importToken() {
            case .token(let imported): return imported
            case .unavailable(let reason):
                throw SetupError("could not import a token from the GitHub CLI: \(reason)")
            }
        case .interactive: throw SetupError("interactive token capture is available through yh setup")
        case .never: throw SetupError("a token source is required")
        }
    }

    private func store(
        _ token: String, for reference: CredentialReference, name: String, replacing: Bool,
        configuration: Configuration?
    ) throws {
        if !replacing, credentials.presence(of: reference) != .absent {
            throw SetupError(
                "a Keychain item already exists for \(reference.rawValue); remove the stale item before connecting"
            )
        }
        do {
            try credentials.store(token, for: reference)
        } catch {
            throw SetupError("could not store the GitHub token for \(reference.rawValue) in the Keychain: \(error)")
        }
        guard !replacing else { return }
        do {
            try saveConnection(
                CodeHostingConnection(name: name, kind: .keychainToken(reference)), configuration: configuration
            )
        } catch {
            try? credentialDeleter.delete(reference)
            throw SetupError("could not update the Code Hosting Connection registry: \(error)")
        }
    }

    private func saveConnection(_ connection: CodeHostingConnection, configuration: Configuration?) throws {
        let machine = configuration?.machine ?? MachineConfiguration(cliAdapters: [], routingTable: [])
        let original = try? String(contentsOf: machineURL, encoding: .utf8)
        let edited = original.map { MachineConfiguration.settingCodeHostingConnection(connection, inFileText: $0) }
            ?? MachineConfiguration(
                linearInstallations: machine.linearInstallations,
                codeHostingConnections: [connection], cliAdapters: machine.cliAdapters,
                routingTable: machine.routingTable
            ).renderedTOML
        try Configuration.save(edited, to: machineURL, in: directory, replacing: original)
    }

    func remove(name: String) throws {
        guard FileManager.default.fileExists(atPath: machineURL.path(percentEncoded: false)) else {
            throw SetupError("no machine configuration is set up")
        }
        let configuration = try Configuration.loadLeniently(directory: directory)
        guard let connection = configuration.machine.codeHostingConnection(named: name) else {
            throw SetupError("no Code Hosting Connection is named \"\(name)\"")
        }
        if let invalid = configuration.invalidProjects.first {
            throw SetupError(
                "Code Hosting Connection \"\(name)\" was not removed: Project file \(invalid.file) could not be decoded"
            )
        }
        if case .keychainToken(let reference) = connection.kind,
           configuration.machine.codeHostingConnections.contains(where: { other in
               guard other.name != name, case .keychainToken(let otherReference) = other.kind else { return false }
               return otherReference == reference
           }) {
            throw SetupError(
                "Code Hosting Connection \"\(name)\" was not removed: its Keychain item is shared by another connection"
            )
        }
        let projects = configuration.projects.filter { $0.codeHostingConnectionName == name }
            .map { $0.id.rawValue }.sorted()
        guard projects.isEmpty else {
            throw SetupError(
                "Code Hosting Connection \"\(name)\" was not removed: selected by Projects "
                    + "\(projects.joined(separator: ", ")); change their selection first"
            )
        }
        let original = try String(contentsOf: machineURL, encoding: .utf8)
        if case .keychainToken(let reference) = connection.kind {
            try credentialDeleter.delete(reference)
        }
        let edited = MachineConfiguration.removingCodeHostingConnection(named: name, inFileText: original)
        try Configuration.save(edited, to: machineURL, in: directory, replacing: original)
        output("Code Hosting Connection \(name) removed.")
    }

    func report() async throws -> CodeHostingConnectionsReport {
        guard let configuration = try load() else {
            let empty = CodeHostingConnectionsReport(connections: [])
            output(empty.encodeLine())
            return empty
        }
        var reports: [CodeHostingConnectionsReport.Connection] = []
        for connection in configuration.machine.codeHostingConnections {
            let projects = configuration.projects.filter { $0.codeHostingConnectionName == connection.name }
                .map { $0.id.rawValue }.sorted()
            switch connection.kind {
            case .githubCLI(let executable):
                let result = await gitHub.reportGitHubCLI(
                    executable: executable, repos: [], connectionName: connection.name
                )
                let ok = result.state == .resolves
                reports.append(.init(
                    name: connection.name, type: .gh, identity: result.login,
                    state: ok ? .ok : .refused, reason: ok ? nil : result.message, projects: projects
                ))
            case .keychainToken(let reference):
                let result = await gitHub.report(
                    reference: reference, secret: credentials.gitHubSecret(for: reference), repos: [],
                    connectionName: connection.name
                )
                let ok = result.state == .resolves
                reports.append(.init(
                    name: connection.name, type: .keychain, identity: result.login,
                    state: ok ? .ok : .refused, reason: ok ? nil : result.message, projects: projects
                ))
            }
        }
        let result = CodeHostingConnectionsReport(connections: reports)
        output(result.encodeLine())
        return result
    }

    func checkCredential(connection name: String?, repoPaths: [String]) async throws -> GitHubCredentialReport {
        let connectionName = name ?? CodeHostingConnection.defaultName
        let fallback = CodeHostingConnection.defaultCredentialReference(for: connectionName)
        guard let configuration = try load(),
              let connection = configuration.machine.codeHostingConnection(named: connectionName) else {
            let report = GitHubCredentialReport(
                reference: fallback.rawValue, state: .missing,
                message: "No Code Hosting Connection named \(connectionName) is connected. Connect it with "
                    + "`yh config connect-code-hosting \(connectionName) --token-stdin`."
            )
            output(report.encodeLine())
            return report
        }
        let repos = repoPaths.map { path in (name: URL(fileURLWithPath: path).lastPathComponent, path: path) }
        let report: GitHubCredentialReport
        switch connection.kind {
        case .githubCLI(let executable):
            report = await gitHub.reportGitHubCLI(executable: executable, repos: repos, connectionName: connectionName)
        case .keychainToken(let reference):
            report = await gitHub.report(
                reference: reference, secret: credentials.gitHubSecret(for: reference), repos: repos,
                connectionName: connectionName
            )
        }
        output(report.encodeLine())
        return report
    }

    private func load() throws -> Configuration? {
        guard FileManager.default.fileExists(atPath: machineURL.path(percentEncoded: false)) else { return nil }
        return try Configuration.loadLeniently(directory: directory)
    }
}

public struct ConfigConnectCodeHostingCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "connect-code-hosting",
        abstract: "Connect a GitHub token, or the GitHub CLI itself, under a local name."
    )
    @Argument public var name: String
    @Flag(name: .customLong("token-stdin")) public var tokenStdin = false
    @Flag(name: .customLong("from-gh")) public var fromGH = false
    @Flag(
        name: .customLong("gh-cli"),
        help: "Connect the GitHub CLI itself; Yellowhammer holds no token."
    ) public var ghCLI = false
    public init() {}
    public func validate() throws {
        guard [tokenStdin, fromGH, ghCLI].filter({ $0 }).count == 1 else {
            throw ValidationError("choose exactly one of --token-stdin, --from-gh or --gh-cli")
        }
    }
    public func run() async throws {
        let manager = manager()
        if ghCLI {
            try await manager.connectGitHubCLI(name: name)
        } else {
            try await manager.connect(name: name, source: tokenStdin ? .standardInput : .githubCLI)
        }
    }
}

public struct ConfigReplaceCodeHostingTokenCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "replace-code-hosting-token", abstract: "Validate and replace a Code Hosting Connection token."
    )
    @Argument public var name: String
    @Flag(name: .customLong("token-stdin")) public var tokenStdin = false
    @Flag(name: .customLong("from-gh")) public var fromGH = false
    public init() {}
    public func validate() throws {
        guard tokenStdin != fromGH else { throw ValidationError("choose exactly one of --token-stdin or --from-gh") }
    }
    public func run() async throws {
        try await manager().connect(
            name: name, source: tokenStdin ? .standardInput : .githubCLI, replacing: true
        )
    }
}

public struct ConfigRemoveCodeHostingConnectionCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove-code-hosting-connection", abstract: "Remove an unselected Code Hosting Connection."
    )
    @Argument public var name: String
    public init() {}
    public func run() async throws { try manager().remove(name: name) }
}

public struct ConfigPrintCodeHostingConnectionsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "print-code-hosting-connections", abstract: "Print the Code Hosting Connection registry as JSON."
    )
    public init() {}
    public func run() async throws { _ = try await manager().report() }
}

public struct ConfigCheckCodeHostingCredentialCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check-code-hosting-credential", abstract: "Check a Code Hosting token and its Repo access."
    )
    @Option(name: .customLong("connection")) public var connection: String?
    @Option(name: .customLong("github-repo")) public var repoPaths: [String] = []
    public init() {}
    public func validate() throws {
        if let connection, connection.isEmpty {
            throw ValidationError("--connection must not be empty")
        }
        guard repoPaths.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError("--github-repo paths must not be empty")
        }
    }
    public func run() async throws {
        _ = try await manager().checkCredential(connection: connection, repoPaths: repoPaths)
    }
}

private extension AsyncParsableCommand {
    func manager() -> CodeHostingConnectionManager {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CodeHostingConnectionManager(
            directory: Configuration.defaultDirectoryURL(homeDirectory: home), output: { print($0) },
            credentials: KeychainSetupCredentialStore(), credentialDeleter: KeychainInstallationCredentialDeleter(),
            gitHub: .production(),
            importToken: GitHubTokenImport.production(
                path: ProcessInfo.processInfo.environment["PATH"],
                fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
            ),
            console: RealSetupConsole()
        )
    }
}
