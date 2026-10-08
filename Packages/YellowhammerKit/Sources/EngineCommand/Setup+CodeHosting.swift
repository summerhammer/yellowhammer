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

    /// `name` must be in the registry; unless the GitHub check is skipped it must also be usable, which
    /// refuses a `gh` CLI connection with the resolver's own description.
    private func requireRegistered(_ name: String, machine: MachineConfiguration) throws -> String {
        guard machine.codeHostingConnection(named: name) != nil else {
            throw SetupError(
                "\(name) is not a connected Code Hosting Connection (" + connectedListing(machine, fixing: name) + ")"
            )
        }
        if !options.skipGitHubCheck {
            _ = try codeHostingReference(of: name, machine: machine)
        }
        return name
    }

    /// `connected: a, b`, or how to connect the first one.
    private func connectedListing(_ machine: MachineConfiguration, fixing name: String?) -> String {
        let names = machine.codeHostingConnections.map(\.name)
        guard names.isEmpty else { return "connected: " + names.joined(separator: ", ") }
        let suggestedName = name ?? CodeHostingConnection.defaultName
        return "none are connected; connect one with `yh config connect-code-hosting \(suggestedName) --token-stdin`"
    }

    /// Lists the registry plus "Connect a GitHub token (Keychain)…" and asks which one this run uses. An empty,
    /// non-numeric or out-of-range answer re-asks, and so does a `gh` CLI connection the GitHub check could
    /// not use; EOF cancels. With the check skipped nothing is connected here, so an empty registry is an error.
    private func askCodeHostingConnection(machine: inout MachineConfiguration) async throws -> String {
        let entries = machine.codeHostingConnections
        let canConnect = !options.skipGitHubCheck
        guard !entries.isEmpty else {
            guard canConnect else {
                throw SetupError(
                    "no Code Hosting Connection is connected, and --skip-github-check connects none; "
                        + "run yh config connect-code-hosting github --token-stdin first"
                )
            }
            return try await connectKeychainTokenConnection(machine: &machine)
        }
        let connectNumber = listCodeHostingConnections(entries, offeringToConnect: canConnect)
        let last = canConnect ? connectNumber : entries.count
        while true {
            guard let line = console.ask("Choose [1-\(last)]: ") else { throw SetupError("setup was cancelled") }
            guard let number = Int(line.trimmingCharacters(in: .whitespaces)), (1...last).contains(number) else {
                continue
            }
            if canConnect && number == connectNumber {
                return try await connectKeychainTokenConnection(machine: &machine)
            }
            let name = entries[number - 1].name
            do {
                return try requireRegistered(name, machine: machine)
            } catch {
                output("\(error)")
            }
        }
    }

    /// Prints the numbered list and returns the number of the "Connect…" line, which is only printed when
    /// `offeringToConnect`.
    private func listCodeHostingConnections(_ entries: [CodeHostingConnection], offeringToConnect: Bool) -> Int {
        output("Code Hosting Connections:")
        for (index, entry) in entries.enumerated() {
            let type = switch entry.kind {
            case .githubCLI: "gh CLI"
            case .keychainToken: "Keychain token"
            }
            output("  \(index + 1)) \(entry.name) — \(type)")
        }
        let connectNumber = entries.count + 1
        if offeringToConnect { output("  \(connectNumber)) Connect a GitHub token (Keychain)…") }
        return connectNumber
    }

    /// Asks a local name, captures and authenticates a token for `keychain:<name>`, and only once GitHub
    /// accepts it adds the connection to `config.toml` and to `machine`.
    private func connectKeychainTokenConnection(machine: inout MachineConfiguration) async throws -> String {
        let name = try askConnectionName(taken: Set(machine.codeHostingConnections.map(\.name)))
        let reference = CodeHostingConnection.defaultCredentialReference(for: name)
        _ = try await ensureGitHubCredential(reference: reference, capture: .interactive, replace: false)
        try addCodeHostingConnection(CodeHostingConnection(name: name, kind: .keychainToken(reference)))
        do {
            machine = try MachineConfiguration.load(contentsOf: machineFileURL)
        } catch {
            throw SetupError("\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)")
        }
        return name
    }

    /// The local name for a new connection: `github` when unused is the default. It must be a valid local name
    /// and unused; anything else re-asks. EOF cancels.
    private func askConnectionName(taken: Set<String>) throws -> String {
        let proposal = taken.contains(CodeHostingConnection.defaultName) ? nil : CodeHostingConnection.defaultName
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
