import Config
import Domain
import LinearAdapter

extension Setup {
    /// The Linear step (roadmap P17.6; spec: board-projection/install-the-linear-app): installs when no
    /// Installation token pair exists yet, re-authorizes an existing one, and offers to reinstall when
    /// Linear refuses it (a revoked installation, or an expired sign-in). Returns the workspace members
    /// — the immediate authorization proof — for the Operator identity choice that follows.
    func authorizeOrInstallLinear(
        machine: inout MachineConfiguration
    ) async throws -> (members: [BoardMember], installation: LinearInstallation) {
        if case .installLinear = options.mode {
            // "Re-running the Linear step of setup" always re-installs, whether or not the existing
            // pair (if any) still authorizes — it is the general fix action, and also usable proactively.
            try await runLinearInstall(machine: &machine)
        } else if let sole = machine.soleLinearInstallation, credentials.secret(for: sole.credential) != nil {
            let board = bindProvisioning(sole, "")
            do {
                return (try await board.workspaceMembers(), sole)
            } catch BoardError.notAuthenticated {
                try await handleRefusedInstallation(machine: &machine)
            } catch {
                throw SetupError("Linear authorization failed: \(error)")
            }
        } else {
            try await runLinearInstall(machine: &machine)
        }
        // The bridge (roadmap L3.2 deletes it): this version of setup connects one Linear workspace, so the
        // install just stored is the registry's only entry.
        guard let installation = machine.soleLinearInstallation else {
            throw SetupError(
                "config.toml declares \(machine.linearInstallations.count) Linear App Installations; "
                    + "this version of yh setup connects one"
            )
        }
        return (try await authorize(board: bindProvisioning(installation, "")), installation)
    }

    /// `workspaceMembers()` is the authorization proof: it is the first call this Linear identity makes.
    func authorize(board: any BoardProvisioning) async throws -> [BoardMember] {
        do {
            return try await board.workspaceMembers()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }

    private func handleRefusedInstallation(machine: inout MachineConfiguration) async throws {
        guard isInteractive else {
            throw SetupError(
                "Linear refused the installation; re-run the Linear step: yh setup --install-linear"
            )
        }
        output("Linear refused the installation (revoked, or its sign-in expired).")
        guard let line = console.ask("Install again? [y/n]: "),
              ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            throw SetupError("Linear authorization failed: the installation was refused")
        }
        try await runLinearInstall(machine: &machine)
    }

    /// Decides which install path to take, then runs it to completion (roadmap P17.9): `--remote`
    /// always takes the remote-approval path; otherwise, interactive human mode asks once whether the
    /// Operator is a workspace admin, before anything else. Every other mode (including `--events json`)
    /// keeps the local, loopback-browser path unchanged.
    func runLinearInstall(machine: inout MachineConfiguration) async throws {
        if options.remoteApproval {
            try await runLinearRemoteInstall(machine: &machine)
            return
        }
        if isInteractive {
            let answer = console.ask(
                "Are you a Linear workspace admin? [i]nstall here as the admin, "
                    + "or [r]equest approval from an admin: "
            )
            let trimmed = (answer ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("r") {
                try await runLinearRemoteInstall(machine: &machine)
                return
            }
        }
        try await runLinearLocalInstall(machine: &machine)
    }

    /// `handleFailedAttempt`'s own answer: retry the same local attempt, or switch to the remote-approval
    /// path (roadmap P17.9).
    private enum LocalRetryDecision {
        case retry
        case switchToRemote
    }

    /// Runs the browser install to completion: prints (or emits, under `--events json`) the admin
    /// statement, retries on `portsBusy`/`cancelled`/`notCompleted` when interactive, refuses a
    /// different workspace, and stores the pair under that installation's lock once accepted (P17.6 items 1–3).
    func runLinearLocalInstall(machine: inout MachineConfiguration) async throws {
        let adminText = LinearInstallCopy.beforeBrowser(teams: await candidateTeams(machine: machine))
        report(.adminStatement(text: adminText), text: adminText)

        let flow = linearInstallSeams.makeFlow(events: makeLocalFlowEvents())
        while true {
            let outcome = try await flow.run()
            if try await handleLocalOutcome(outcome, machine: &machine) {
                continue
            }
            return
        }
    }

    /// `--events json`'s two local-flow events (`browserOpened`/`awaitingApproval`); a no-op otherwise.
    private func makeLocalFlowEvents() -> @Sendable (LinearInstallFlow.Event) -> Void {
        let eventsJSON = options.eventsJSON
        let emit = linearInstallEvents
        return { event in
            switch event {
            case .browserOpening(let url):
                if eventsJSON { emit(.browserOpened(url: url.absoluteString)) }
            case .awaitingCallback:
                if eventsJSON { emit(.awaitingApproval) }
            case .portBound:
                break
            }
        }
    }

    /// `true` to retry the local attempt from the top (`portsBusy`, or `handleFailedAttempt`'s own
    /// retry); `false` once installed, or once the remote-approval path ran to completion.
    private func handleLocalOutcome(
        _ outcome: LinearInstallFlow.Outcome, machine: inout MachineConfiguration
    ) async throws -> Bool {
        switch outcome {
        case .portsBusy(let busy):
            try await handlePortsBusy(busy)
            return true
        case .cancelled:
            return try await handleFailedAttempt(
                reason: .cancelled, text: LinearInstallCopy.nonAdmin, machine: &machine
            )
        case .notCompleted(let linearError):
            let text = "\(LinearInstallCopy.nonAdmin) Linear said: \(linearError)"
            return try await handleFailedAttempt(reason: .notCompleted, text: text, machine: &machine)
        case .installed(let tokens, let identity):
            try await storeInstalled(tokens: tokens, identity: identity, machine: &machine)
            return false
        }
    }

    /// Shared by every non-installed remote outcome: `--events json` emits `.failed` and always throws;
    /// interactive human mode prints `text` and asks `prompt`, resolving the answer through `decide`
    /// (`nil` — including EOF or non-interactive — throws, ending the loop). Used by
    /// `Setup+LinearRemoteAuthorization` too.
    func handleRemoteFailedAttempt<Decision>(
        reason: LinearInstallEvent.FailureReason, text: String, prompt: String,
        decide: (String) -> Decision?
    ) async throws -> Decision {
        if options.eventsJSON {
            linearInstallEvents(.failed(reason: reason, text: text))
            throw SetupError(text)
        }
        output(text)
        guard isInteractive, let line = console.ask(prompt),
              let decision = decide(line.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            throw SetupError(text)
        }
        return decision
    }

    /// `true` to retry the same attempt from the top (a fresh port bind, a fresh browser tab); `false`/
    /// throw ends the loop. `--events json` never prompts — it always fails, naming the reason.
    private func handlePortsBusy(_ busy: [(port: Int, holder: PortHolder?)]) async throws {
        let text = LinearInstallCopy.portsBusy(busy)
        let rows = busy.map {
            LinearInstallEvent.PortRow(port: $0.port, pid: $0.holder?.pid, command: $0.holder?.command)
        }
        if options.eventsJSON {
            linearInstallEvents(.portsBusy(ports: rows, text: text))
            linearInstallEvents(.failed(reason: .portsBusy, text: text))
            throw SetupError(text)
        }
        output(text)
        guard isInteractive, let line = console.ask("[r]etry or [c]ancel? "),
              line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("r")
        else {
            throw SetupError(text)
        }
    }

    /// Shared by `.cancelled` and `.notCompleted`: prints/emits the non-admin copy (plus Linear's own
    /// text for `.notCompleted`), then offers to try again or switch to the remote-approval path
    /// (roadmap P17.9) when interactive. `true` to retry the same local attempt; `false` once the
    /// remote-approval path has already run to completion.
    private func handleFailedAttempt(
        reason: LinearInstallEvent.FailureReason, text: String, machine: inout MachineConfiguration
    ) async throws -> Bool {
        let decision = try await handleRemoteFailedAttempt(
            reason: reason, text: text, prompt: "[t]ry again, [r]equest approval from an admin, or [c]ancel? "
        ) { answer -> LocalRetryDecision? in
            if answer.hasPrefix("r") { return .switchToRemote }
            return answer.hasPrefix("t") ? .retry : nil
        }
        guard case .switchToRemote = decision else { return true }
        try await runLinearRemoteInstall(machine: &machine)
        return false
    }

    /// The interim local name of a registry entry created by `yh setup`, until roadmap L2.1 replaces it
    /// with the workspace's URL key: the workspace name lowercased, every run of characters outside
    /// `[a-z0-9]` collapsed to one `-`, `-` trimmed at both ends, and `linear` when nothing is left.
    static func interimInstallationName(workspaceName: String) -> String {
        var name = ""
        var pendingDash = false
        for scalar in workspaceName.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !name.isEmpty { name += "-" }
                pendingDash = false
                name.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return name.isEmpty ? "linear" : name
    }

    /// Stores a finished install. An entry already in the registry for the installed workspace is
    /// re-connected (tokens under its credential, its `app_user` refreshed, its Operator identity kept); an
    /// empty registry gets a new entry; a different workspace than the registry's is refused outright
    /// (decided with the user): nothing is stored, and the fix is to remove every configured Project first.
    /// Tokens are stored under that installation's lock (so a concurrent Act never reads a half-written pair).
    func storeInstalled(
        tokens: LinearInstallFlow.InstalledTokens, identity: LinearInstallFlow.InstalledIdentity,
        machine: inout MachineConfiguration
    ) async throws {
        let workspace = BoardObjectID(rawValue: identity.workspaceID)
        let appUser = BoardObjectID(rawValue: identity.appUserID)
        var installation: LinearInstallation
        if let existing = machine.linearInstallations.first(where: { $0.workspace == workspace }) {
            installation = existing
            installation.appUser = appUser
        } else if machine.linearInstallations.isEmpty {
            let name = Self.interimInstallationName(workspaceName: identity.workspaceName)
            let credential = options.linearCredential ?? CredentialReference("keychain:linear-\(name)")
            guard let credential else { throw SetupError("a credential reference must not be empty") }
            installation = LinearInstallation(
                name: name, credential: credential, workspace: workspace, appUser: appUser
            )
        } else {
            let text = "This installation is in Linear workspace \(identity.workspaceName), but " +
                "Yellowhammer is set up for a different workspace. This version of yh setup connects one " +
                "Linear workspace; remove its Projects first (yh project remove <id>), then re-run setup."
            if options.eventsJSON {
                linearInstallEvents(.failed(reason: .differentWorkspace, text: text))
            }
            throw SetupError(text)
        }

        let pair = LinearTokenPair(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt
        )
        let store = linearInstallationStore(installation)
        do {
            try await store.tokenStore.withRefreshLock {
                try store.tokenStore.write(pair)
            }
        } catch {
            throw SetupError("could not store the Installation's tokens: \(error)")
        }

        try writeLinearInstallation(installation)
        if let index = machine.linearInstallations.firstIndex(where: { $0.name == installation.name }) {
            machine.linearInstallations[index] = installation
        } else {
            machine.linearInstallations.append(installation)
        }

        let text = "Yellowhammer is installed in the Linear workspace \(identity.workspaceName)."
        report(.installed(workspaceName: identity.workspaceName), text: text)
    }

    private func writeLinearInstallation(_ installation: LinearInstallation) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.settingLinearInstallation(installation, inFileText: text)
        do {
            _ = try MachineConfiguration.parse(updated, file: path)
        } catch {
            throw SetupError("could not set the Linear Installation: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }

    /// Best effort (P17.6 item 2): the teams of `--linear-team` on this run, plus — when an existing
    /// installation still authorizes (the re-install case) — every configured Project's own Linear
    /// project's teams. Every board call here is best effort: a failure names no team rather than
    /// failing the install.
    func candidateTeams(machine: MachineConfiguration) async -> [BoardTeam] {
        var teams: [BoardTeam] = []
        var seen: Set<BoardObjectID> = []

        if let key = options.linearTeam {
            let team = await resolveTeamByKey(key, machine: machine)
            if seen.insert(team.id).inserted { teams.append(team) }
        }
        if await existingInstallationStillAuthorizes(machine: machine) {
            for team in await configuredProjectTeams(machine: machine) where seen.insert(team.id).inserted {
                teams.append(team)
            }
        }
        return teams
    }

    private func resolveTeamByKey(_ key: String, machine: MachineConfiguration) async -> BoardTeam {
        guard
            let sole = machine.soleLinearInstallation,
            let allTeams = try? await bindProvisioning(sole, "").teams(),
            let match = allTeams.first(where: { $0.key == key })
        else {
            return BoardTeam(id: BoardObjectID(rawValue: key), key: key, name: key)
        }
        return match
    }

    private func existingInstallationStillAuthorizes(machine: MachineConfiguration) async -> Bool {
        guard let sole = machine.soleLinearInstallation, credentials.secret(for: sole.credential) != nil else {
            return false
        }
        return (try? await bindProvisioning(sole, "").workspaceMembers()) != nil
    }

    /// Every configured Project's Linear project's teams (best effort, one board call each, errors
    /// ignored) — the re-install case, so the admin statement still names every team Yellowhammer needs.
    private func configuredProjectTeams(machine: MachineConfiguration) async -> [BoardTeam] {
        guard let configuration = try? Configuration.load(directory: configurationDirectory) else { return [] }
        var teams: [BoardTeam] = []
        for project in configuration.projects {
            guard
                let installation = machine.linearInstallation(for: project),
                let scope = try? await bindProvisioning(installation, project.linearProject).linearProject()
            else {
                continue
            }
            teams.append(contentsOf: scope.teams)
        }
        return teams
    }

    /// `--events json` reports only the structured event; every other mode prints `text`. Used by
    /// `Setup+LinearRemoteAuthorization` too.
    func report(_ event: LinearInstallEvent, text: String) {
        if options.eventsJSON {
            linearInstallEvents(event)
        } else {
            output(text)
        }
    }
}
