import Config
import Domain

/// Which Linear App Installation a `yh setup` run acts on (roadmap L2.1), decided before any Linear call.
extension Setup {
    /// What the run does about Linear.
    enum LinearRequest {
        /// No run-level Linear step: no authorization, no Operator step. Provisioning and jobs still
        /// run per Project, through each Project's own installation.
        case skip
        /// Connect a Linear workspace: untargeted (`nil`), or a re-connect aimed at one registry entry.
        case connect(LinearInstallation?)
        /// Act on this registry entry, re-connecting it first when Linear refuses it.
        case use(LinearInstallation)
    }

    /// Resolves `--installation` and the registry into a ``LinearRequest``, or refuses. Refusals write
    /// nothing and call nothing.
    func resolveLinearRequest(machine: MachineConfiguration) throws -> LinearRequest {
        let names = machine.linearInstallations.map(\.name)
        if let name = options.installation {
            guard let entry = machine.linearInstallation(named: name) else {
                throw SetupError(Self.unknownInstallationMessage(name, connected: names))
            }
            if case .installLinear = options.mode { return .connect(entry) }
            return .use(entry)
        }
        if case .installLinear = options.mode { return .connect(nil) }
        if names.isEmpty { return .connect(nil) }
        switch options.mode {
        case .interactive:
            return try askInstallation(machine.linearInstallations)
        case .initialize, .config:
            if let id = options.projectID {
                throw SetupError(
                    "name the Linear App Installation for Project \(id.rawValue) with --installation: "
                        + names.joined(separator: ", ")
                )
            }
            if options.operatorID != nil {
                throw SetupError("--operator needs --installation <name> when Linear workspaces are connected")
            }
            return .skip
        case .installLinear, .printChoices:
            return .skip
        }
    }

    /// Lists the registry plus "Connect another Linear workspace…" and asks which one this run acts on.
    /// The workspace is shown by ID: its name needs a live read, which setup does not make here. An empty,
    /// non-numeric or out-of-range answer re-asks; EOF cancels.
    private func askInstallation(_ entries: [LinearInstallation]) throws -> LinearRequest {
        output("Linear workspaces:")
        for (index, entry) in entries.enumerated() {
            let operatorText = entry.operatorIdentity.map { "Operator \($0.rawValue)" } ?? "Operator not chosen"
            output("  \(index + 1)) \(entry.name) — workspace \(entry.workspace.rawValue), \(operatorText)")
        }
        let connectNumber = entries.count + 1
        output("  \(connectNumber)) Connect another Linear workspace…")
        while true {
            guard let line = console.ask("Choose [1-\(connectNumber)]: ") else {
                throw SetupError("setup was cancelled")
            }
            guard let number = Int(line.trimmingCharacters(in: .whitespaces)),
                  (1...connectNumber).contains(number)
            else {
                continue
            }
            return number == connectNumber ? .connect(nil) : .use(entries[number - 1])
        }
    }

    static func unknownInstallationMessage(_ name: String, connected names: [String]) -> String {
        let listing = names.isEmpty
            ? "none are connected; connect one with yh setup --install-linear"
            : "connected: \(names.joined(separator: ", "))"
        return "\(name) is not a connected Linear App Installation (\(listing))"
    }

    /// Runs the request: the installation the run acts on and the workspace members (the immediate
    /// authorization proof) for the Operator identity choice, or `nil` for `.skip`.
    func authorizeLinear(
        _ request: LinearRequest, machine: inout MachineConfiguration
    ) async throws -> (members: [BoardMember], installation: LinearInstallation)? {
        switch request {
        case .skip:
            return nil
        case .connect(let target):
            let installation = try await runLinearInstall(machine: &machine, target: target)
            return (try await authorize(board: bindProvisioning(installation, "")), installation)
        case .use(let entry):
            return try await authorizeExisting(entry, machine: &machine)
        }
    }

    private func authorizeExisting(
        _ entry: LinearInstallation, machine: inout MachineConfiguration
    ) async throws -> (members: [BoardMember], installation: LinearInstallation) {
        if credentials.secret(for: entry.credential) != nil {
            do {
                return (try await bindProvisioning(entry, "").workspaceMembers(), entry)
            } catch BoardError.notAuthenticated {
                try confirmReconnect(entry, refusedByLinear: true)
            } catch {
                throw SetupError("Linear authorization failed: \(error)")
            }
        } else {
            try confirmReconnect(entry, refusedByLinear: false)
        }
        let installation = try await runLinearInstall(machine: &machine, target: entry)
        return (try await authorize(board: bindProvisioning(installation, "")), installation)
    }

    /// Interactive: re-connects `entry`, asking first when Linear refused it (a missing token pair just
    /// re-connects). Anything else throws the re-connect command.
    private func confirmReconnect(_ entry: LinearInstallation, refusedByLinear: Bool) throws {
        let message = "Linear refused the App Installation \(entry.name); "
            + "re-connect it: yh setup --install-linear --installation \(entry.name)"
        guard isInteractive else { throw SetupError(message) }
        guard refusedByLinear else {
            output("The App Installation \(entry.name) has no stored tokens; re-connecting it.")
            return
        }
        output("Linear refused the App Installation \(entry.name) (revoked, or its sign-in expired).")
        guard let line = console.ask("Re-connect \(entry.name)? [y/n]: "),
              ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            throw SetupError(message)
        }
    }
}
