import Config
import Domain
import LinearAdapter

extension Setup {
    /// The Linear step (roadmap P17.6; spec: board-projection/install-the-linear-app): installs when no
    /// Installation token pair exists yet, re-authorizes an existing one, and offers to reinstall when
    /// Linear refuses it (a revoked installation, or an expired sign-in). Returns the workspace members
    /// — the immediate authorization proof — for the Operator identity choice that follows.
    func authorizeOrInstallLinear(machine: inout MachineConfiguration) async throws -> [BoardMember] {
        if case .installLinear = options.mode {
            // "Re-running the Linear step of setup" always re-installs, whether or not the existing
            // pair (if any) still authorizes — it is the general fix action, and also usable proactively.
            try await runLinearInstall(machine: &machine)
        } else if credentials.secret(for: machine.linearCredential) == nil {
            try await runLinearInstall(machine: &machine)
        } else {
            let board = bindProvisioning(machine, "")
            do {
                return try await board.workspaceMembers()
            } catch BoardError.notAuthenticated {
                try await handleRefusedInstallation(machine: &machine)
            } catch {
                throw SetupError("Linear authorization failed: \(error)")
            }
        }
        return try await authorize(board: bindProvisioning(machine, ""))
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

    /// Runs the browser install to completion: prints (or emits, under `--events json`) the admin
    /// statement, retries on `portsBusy`/`cancelled`/`notCompleted` when interactive, refuses a
    /// different workspace, and stores the pair under the `MachineLock` once accepted (P17.6 items 1–3).
    func runLinearInstall(machine: inout MachineConfiguration) async throws {
        let adminText = LinearInstallCopy.beforeBrowser(teams: await candidateTeams(machine: machine))
        report(.adminStatement(text: adminText), text: adminText)

        let eventsJSON = options.eventsJSON
        let emit = linearInstallEvents
        let flow = linearInstallSeams.makeFlow(events: { event in
            switch event {
            case .browserOpening(let url):
                if eventsJSON { emit(.browserOpened(url: url.absoluteString)) }
            case .awaitingCallback:
                if eventsJSON { emit(.awaitingApproval) }
            case .portBound:
                break
            }
        })

        while true {
            switch try await flow.run() {
            case .portsBusy(let busy):
                try await handlePortsBusy(busy)
            case .cancelled:
                try await handleFailedAttempt(reason: .cancelled, text: LinearInstallCopy.nonAdmin)
            case .notCompleted(let linearError):
                let text = "\(LinearInstallCopy.nonAdmin) Linear said: \(linearError)"
                try await handleFailedAttempt(reason: .notCompleted, text: text)
            case .installed(let tokens, let identity):
                try await storeInstalled(tokens: tokens, identity: identity, machine: &machine)
                return
            }
        }
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
    /// text for `.notCompleted`), then offers to try again when interactive.
    private func handleFailedAttempt(reason: LinearInstallEvent.FailureReason, text: String) async throws {
        if options.eventsJSON {
            linearInstallEvents(.failed(reason: reason, text: text))
            throw SetupError(text)
        }
        output(text)
        guard isInteractive, let line = console.ask("Try again? [y/n]: "),
              ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
        else {
            throw SetupError(text)
        }
    }

    /// A different workspace is refused outright (decided with the user): nothing is stored, and the
    /// fix is to remove every configured Project first. Otherwise stores the pair under the
    /// `MachineLock` (so a concurrent Act never reads a half-written pair), writes `workspace`/`app_user`,
    /// and reports the workspace name.
    private func storeInstalled(
        tokens: LinearInstallFlow.InstalledTokens, identity: LinearInstallFlow.InstalledIdentity,
        machine: inout MachineConfiguration
    ) async throws {
        let newWorkspace = BoardObjectID(rawValue: identity.workspaceID)
        if let existing = machine.linearWorkspace, existing != newWorkspace {
            let text = "This installation is in Linear workspace \(identity.workspaceName), but " +
                "Yellowhammer is set up for a different workspace. Remove its Projects first " +
                "(yh project remove <id>), then re-run setup."
            if options.eventsJSON {
                linearInstallEvents(.failed(reason: .differentWorkspace, text: text))
            }
            throw SetupError(text)
        }

        let pair = LinearTokenPair(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt
        )
        let store = linearInstallationStore(machine.linearCredential)
        do {
            try await store.tokenStore.withRefreshLock {
                try store.tokenStore.write(pair)
            }
        } catch {
            throw SetupError("could not store the Installation's tokens: \(error)")
        }

        let appUser = BoardObjectID(rawValue: identity.appUserID)
        try writeLinearInstallation(workspace: newWorkspace, appUser: appUser)
        machine.linearWorkspace = newWorkspace
        machine.linearAppUser = appUser

        let text = "Yellowhammer is installed in the Linear workspace \(identity.workspaceName)."
        report(.installed(workspaceName: identity.workspaceName), text: text)
    }

    private func writeLinearInstallation(workspace: BoardObjectID, appUser: BoardObjectID) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.settingLinearInstallation(
            workspace: workspace, appUser: appUser, inFileText: text
        )
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
    private func candidateTeams(machine: MachineConfiguration) async -> [BoardTeam] {
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
            let allTeams = try? await bindProvisioning(machine, "").teams(),
            let match = allTeams.first(where: { $0.key == key })
        else {
            return BoardTeam(id: BoardObjectID(rawValue: key), key: key, name: key)
        }
        return match
    }

    private func existingInstallationStillAuthorizes(machine: MachineConfiguration) async -> Bool {
        guard credentials.secret(for: machine.linearCredential) != nil else { return false }
        return (try? await bindProvisioning(machine, "").workspaceMembers()) != nil
    }

    /// Every configured Project's Linear project's teams (best effort, one board call each, errors
    /// ignored) — the re-install case, so the admin statement still names every team Yellowhammer needs.
    private func configuredProjectTeams(machine: MachineConfiguration) async -> [BoardTeam] {
        guard let configuration = try? Configuration.load(directory: configurationDirectory) else { return [] }
        var teams: [BoardTeam] = []
        for project in configuration.projects {
            guard let scope = try? await bindProvisioning(machine, project.linearProject).linearProject() else {
                continue
            }
            teams.append(contentsOf: scope.teams)
        }
        return teams
    }

    /// `--events json` reports only the structured event; every other mode prints `text`.
    private func report(_ event: LinearInstallEvent, text: String) {
        if options.eventsJSON {
            linearInstallEvents(event)
        } else {
            output(text)
        }
    }
}
