import Config
import Domain
import Foundation

/// Which Code Hosting Connection the Projects a `yh setup` run writes select (connect-code-hosting), decided
/// before any Linear call; and adding a Keychain token connection to the registry.
extension Setup {
    /// The local name of the connection every Project this run writes selects, or nil when the run writes no
    /// Project. `--init` with `--project` requires `--code-hosting-connection`; an interactive run takes it
    /// when given and otherwise asks, offering to connect a new Keychain token connection. A connection added
    /// here is in `config.toml` and in `machine` once its token is accepted.
    func selectCodeHostingConnection(machine: inout MachineConfiguration) async throws -> String? {
        switch options.mode {
        case .initialize:
            guard let id = options.projectID else { return nil }
            guard let name = options.codeHostingConnection else {
                throw SetupError(
                    "name the Code Hosting Connection for Project \(id.rawValue) with --code-hosting-connection: "
                        + connectedListing(machine, fixing: nil)
                )
            }
            return try requireRegistered(name, machine: machine)
        case .interactive:
            if let name = options.codeHostingConnection { return try requireRegistered(name, machine: machine) }
            return try await askCodeHostingConnection(machine: &machine)
        default:
            return nil
        }
    }

    /// Adds `connection` to `config.toml`, creating the file from an unconfigured machine when there is
    /// none, and leaving every other line as it was.
    func addCodeHostingConnection(_ connection: CodeHostingConnection) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        if FileManager.default.fileExists(atPath: path) {
            do {
                text = try String(contentsOf: machineFileURL, encoding: .utf8)
            } catch {
                throw SetupError("could not read \(path): \(error)")
            }
        } else {
            text = MachineConfiguration.unconfigured.renderedTOML.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let updated = MachineConfiguration.settingCodeHostingConnection(connection, inFileText: text)
        do {
            try FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
        output("added Code Hosting Connection \(connection.name) to \(path)")
    }

    static func invalidConnectionNameMessage(_ name: String) -> String {
        "\"\(name)\" is not a valid Code Hosting Connection name: use lowercase letters, digits, \"_\" or \"-\", "
            + "starting with a letter or digit"
    }

    // MARK: - Choosing

    /// `name` must be in the registry; unless the GitHub check is skipped it must also resolve.
    private func requireRegistered(_ name: String, machine: MachineConfiguration) throws -> String {
        guard machine.codeHostingConnection(named: name) != nil else {
            throw SetupError(
                "\(name) is not a connected Code Hosting Connection (" + connectedListing(machine, fixing: name) + ")"
            )
        }
        if !options.skipGitHubCheck {
            _ = try codeHostingCredential(of: name, machine: machine)
        }
        return name
    }

    /// `connected: a, b`, or how to connect the first one.
    private func connectedListing(_ machine: MachineConfiguration, fixing name: String?) -> String {
        let names = machine.codeHostingConnections.map(\.name)
        guard names.isEmpty else { return "connected: " + names.joined(separator: ", ") }
        let suggestedName = name ?? CodeHostingConnection.defaultName
        return "none are connected; connect one with `yh config connect-code-hosting \(suggestedName) --token-stdin`"
            + " (or `yh config connect-code-hosting gh --gh-cli` for the gh CLI)"
    }

    /// What Setup found when it asked the GitHub CLI who it is, before listing the choices.
    private enum GitHubCLIOffer {
        /// gh resolves and is logged in as `login`, and no gh connection is in the registry.
        case loggedIn(login: String)
        /// gh is found but logged out; a hint, no action.
        case loggedOut
        case none
    }

    /// Asks gh who it is, unless the registry already holds a gh connection or the GitHub check is skipped.
    /// Yellowhammer never adds the connection by itself: this only decides what is offered.
    private func gitHubCLIOffer(entries: [CodeHostingConnection]) async -> GitHubCLIOffer {
        guard !options.skipGitHubCheck, !entries.contains(where: { isGitHubCLI($0) }) else { return .none }
        let report = await gitHub.reportGitHubCLI(
            executable: nil, repos: [], connectionName: CodeHostingConnection.gitHubCLIDefaultName
        )
        switch report.state {
        case .resolves: return .loggedIn(login: report.login ?? "unknown")
        case .rejected: return .loggedOut
        case .missing, .unreadable, .unreachable: return .none
        }
    }

    private func isGitHubCLI(_ connection: CodeHostingConnection) -> Bool {
        if case .githubCLI = connection.kind { true } else { false }
    }

    /// Lists the registry, the offer to connect the gh CLI, and "Connect a GitHub token (Keychain)…", and asks
    /// which one this run uses. The gh CLI is pre-selected when it is in the registry, else when it is offered:
    /// an empty answer takes it. Otherwise an empty, non-numeric or out-of-range answer re-asks, and so does a
    /// connection the GitHub check could not use; EOF cancels. With the check skipped nothing is connected
    /// here, so an empty registry is an error.
    private func askCodeHostingConnection(machine: inout MachineConfiguration) async throws -> String {
        let entries = machine.codeHostingConnections
        let canConnect = !options.skipGitHubCheck
        let offer = await gitHubCLIOffer(entries: entries)
        var offeredLogin: String?
        if case .loggedIn(let login) = offer { offeredLogin = login }
        if case .loggedOut = offer { output(Self.gitHubCLILoggedOutHint) }
        guard !entries.isEmpty || offeredLogin != nil else {
            guard canConnect else {
                throw SetupError(
                    "no Code Hosting Connection is connected, and --skip-github-check connects none; "
                        + "run yh config connect-code-hosting github --token-stdin first"
                )
            }
            return try await connectKeychainTokenConnection(machine: &machine)
        }
        let offerNumber = offeredLogin == nil ? nil : entries.count + 1
        let keychainNumber = entries.count + (offerNumber == nil ? 1 : 2)
        let defaultNumber = entries.firstIndex(where: { isGitHubCLI($0) }).map { $0 + 1 } ?? offerNumber
        listCodeHostingConnections(entries, offeredGitHubCLILogin: offeredLogin, offeringKeychain: canConnect)
        let last = canConnect ? keychainNumber : entries.count
        let prompt = "Choose [1-\(last)]" + (defaultNumber.map { " (Enter for \($0))" } ?? "") + ": "
        while true {
            guard let line = console.ask(prompt) else { throw SetupError("setup was cancelled") }
            let answer = line.trimmingCharacters(in: .whitespaces)
            guard let number = answer.isEmpty ? defaultNumber : Int(answer), (1...last).contains(number) else {
                continue
            }
            if number == offerNumber {
                return try await connectGitHubCLIConnection(machine: &machine)
            }
            if canConnect && number == keychainNumber {
                return try await connectKeychainTokenConnection(machine: &machine)
            }
            do {
                return try requireRegistered(entries[number - 1].name, machine: machine)
            } catch {
                output("\(error)")
            }
        }
    }

    private static let gitHubCLILoggedOutHint =
        "gh is installed but not logged in; run `gh auth login` to offer it here"

    /// Prints the numbered list: the registry, then the gh CLI offer (when gh answered), then the Keychain line
    /// (when `offeringKeychain`).
    private func listCodeHostingConnections(
        _ entries: [CodeHostingConnection], offeredGitHubCLILogin: String?, offeringKeychain: Bool
    ) {
        output("Code Hosting Connections:")
        for (index, entry) in entries.enumerated() {
            let type = switch entry.kind {
            case .githubCLI: "gh CLI"
            case .keychainToken: "Keychain token"
            }
            output("  \(index + 1)) \(entry.name) — \(type)")
        }
        var next = entries.count + 1
        if let login = offeredGitHubCLILogin {
            output("  \(next)) Connect the gh CLI (acting as GitHub user \(login))")
            next += 1
        }
        if offeringKeychain { output("  \(next)) Connect a GitHub token (Keychain)…") }
    }

    /// Connects the gh CLI under `gh` (asking for a name when that is taken): it holds no token, so only the
    /// registry entry is written. The Operator picked the line; Setup never does this by itself.
    private func connectGitHubCLIConnection(machine: inout MachineConfiguration) async throws -> String {
        let taken = Set(machine.codeHostingConnections.map(\.name))
        let name = taken.contains(CodeHostingConnection.gitHubCLIDefaultName)
            ? try askConnectionName(taken: taken, proposal: CodeHostingConnection.gitHubCLIDefaultName)
            : CodeHostingConnection.gitHubCLIDefaultName
        try addCodeHostingConnection(CodeHostingConnection(name: name, kind: .githubCLI(executable: nil)))
        try reloadMachine(&machine)
        return name
    }

    private func reloadMachine(_ machine: inout MachineConfiguration) throws {
        do {
            machine = try MachineConfiguration.load(contentsOf: machineFileURL)
        } catch {
            throw SetupError("\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)")
        }
    }

    /// Asks a local name, captures and authenticates a token for `keychain:<name>`, and only once GitHub
    /// accepts it adds the connection to `config.toml` and to `machine`.
    private func connectKeychainTokenConnection(machine: inout MachineConfiguration) async throws -> String {
        let name = try askConnectionName(taken: Set(machine.codeHostingConnections.map(\.name)))
        let reference = CodeHostingConnection.defaultCredentialReference(for: name)
        _ = try await ensureGitHubCredential(reference: reference, capture: .interactive, replace: false)
        try addCodeHostingConnection(CodeHostingConnection(name: name, kind: .keychainToken(reference)))
        try reloadMachine(&machine)
        return name
    }

    /// The local name for a new connection: `proposal` (`github`) when unused is the default. It must be a valid local name
    /// and unused; anything else re-asks. EOF cancels.
    private func askConnectionName(
        taken: Set<String>, proposal defaultProposal: String = CodeHostingConnection.defaultName
    ) throws -> String {
        let proposal = taken.contains(defaultProposal) ? nil : defaultProposal
        let prompt = proposal.map { "Local name for this connection [\($0)]: " } ?? "Local name for this connection: "
        while true {
            guard let line = console.ask(prompt) else { throw SetupError("setup was cancelled") }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let name = trimmed.isEmpty ? proposal : trimmed else { continue }
            guard LinearInstallation.isValidLocalName(name) else {
                output(Self.invalidConnectionNameMessage(name))
                continue
            }
            guard !taken.contains(name) else {
                output("a Code Hosting Connection named \(name) is already connected")
                continue
            }
            return name
        }
    }
}
