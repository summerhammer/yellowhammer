import Config
import Domain
import LinearAdapter

extension Setup {
    /// `workspaceMembers()` is the authorization proof: it is the first call this Linear identity makes.
    func authorize(board: any BoardProvisioning) async throws -> [BoardMember] {
        do {
            return try await board.workspaceMembers()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }

    /// Decides which install path to take, then runs it to completion (roadmap P17.9): `--remote`
    /// always takes the remote-approval path; otherwise, interactive human mode asks once whether the
    /// Operator is a workspace admin, before anything else. Every other mode (including `--events json`)
    /// keeps the local, loopback-browser path unchanged. `target` is the registry entry a re-connect is
    /// aimed at (nil: any workspace); returns the entry the install resulted in.
    func runLinearInstall(
        machine: inout MachineConfiguration, target: LinearInstallation?
    ) async throws -> LinearInstallation {
        if options.remoteApproval {
            return try await runLinearRemoteInstall(machine: &machine, target: target)
        }
        if isInteractive {
            let answer = console.ask(
                "Are you a Linear workspace admin? [i]nstall here as the admin, "
                    + "or [r]equest approval from an admin: "
            )
            let trimmed = (answer ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("r") {
                return try await runLinearRemoteInstall(machine: &machine, target: target)
            }
        }
        return try await runLinearLocalInstall(machine: &machine, target: target)
    }

    /// `handleFailedAttempt`'s own answer: retry the same local attempt, or switch to the remote-approval
    /// path (roadmap P17.9).
    private enum LocalRetryDecision {
        case retry
        case switchToRemote
    }

    /// Runs the browser install to completion: prints (or emits, under `--events json`) the admin
    /// statement, retries on `portsBusy`/`cancelled`/`notCompleted` when interactive, refuses a
    /// a different workspace than the target's, and stores the pair under that installation's lock once accepted (P17.6 items 1–3).
    func runLinearLocalInstall(
        machine: inout MachineConfiguration, target: LinearInstallation?
    ) async throws -> LinearInstallation {
        let adminText = LinearInstallCopy.beforeBrowser(teams: await candidateTeams(machine: machine, target: target))
        report(.adminStatement(text: adminText), text: adminText)

        let flow = linearInstallSeams.makeFlow(events: makeLocalFlowEvents())
        while true {
            let outcome = try await flow.run()
            if let installation = try await handleLocalOutcome(outcome, target: target, machine: &machine) {
                return installation
            }
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

    /// `nil` to retry the local attempt from the top (`portsBusy`, or `handleFailedAttempt`'s own
    /// retry); the resulting entry once installed, or once the remote-approval path ran to completion.
    private func handleLocalOutcome(
        _ outcome: LinearInstallFlow.Outcome, target: LinearInstallation?, machine: inout MachineConfiguration
    ) async throws -> LinearInstallation? {
        switch outcome {
        case .portsBusy(let busy):
            try await handlePortsBusy(busy)
            return nil
        case .cancelled:
            return try await handleFailedAttempt(
                reason: .cancelled, text: LinearInstallCopy.nonAdmin, target: target, machine: &machine
            )
        case .notCompleted(let linearError):
            let text = "\(LinearInstallCopy.nonAdmin) Linear said: \(linearError)"
            return try await handleFailedAttempt(
                reason: .notCompleted, text: text, target: target, machine: &machine
            )
        case .installed(let tokens, let identity):
            return try await storeInstalled(tokens: tokens, identity: identity, target: target, machine: &machine)
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
    /// (roadmap P17.9) when interactive. `nil` to retry the same local attempt; the resulting entry once
    /// the remote-approval path has already run to completion.
    private func handleFailedAttempt(
        reason: LinearInstallEvent.FailureReason, text: String, target: LinearInstallation?,
        machine: inout MachineConfiguration
    ) async throws -> LinearInstallation? {
        let decision = try await handleRemoteFailedAttempt(
            reason: reason, text: text, prompt: "[t]ry again, [r]equest approval from an admin, or [c]ancel? "
        ) { answer -> LocalRetryDecision? in
            if answer.hasPrefix("r") { return .switchToRemote }
            return answer.hasPrefix("t") ? .retry : nil
        }
        guard case .switchToRemote = decision else { return nil }
        return try await runLinearRemoteInstall(machine: &machine, target: target)
    }

    /// Best effort (P17.6 item 2): the teams of `--linear-team` on this run (resolved through the target's
    /// board when there is one), plus — when the target still authorizes (the re-install case) — the teams
    /// of the Linear project of every configured Project that uses the target. Every board call here is
    /// best effort: a failure names no team rather than failing the install.
    func candidateTeams(machine: MachineConfiguration, target: LinearInstallation?) async -> [BoardTeam] {
        var teams: [BoardTeam] = []
        var seen: Set<BoardObjectID> = []

        if let key = options.linearTeam {
            let team = await resolveTeamByKey(key, target: target)
            if seen.insert(team.id).inserted { teams.append(team) }
        }
        if let target, await targetStillAuthorizes(target) {
            for team in await configuredProjectTeams(machine: machine, target: target)
            where seen.insert(team.id).inserted {
                teams.append(team)
            }
        }
        return teams
    }

    private func resolveTeamByKey(_ key: String, target: LinearInstallation?) async -> BoardTeam {
        guard
            let target,
            let allTeams = try? await bindProvisioning(target, "").teams(),
            let match = allTeams.first(where: { $0.key == key })
        else {
            return BoardTeam(id: BoardObjectID(rawValue: key), key: key, name: key)
        }
        return match
    }

    private func targetStillAuthorizes(_ target: LinearInstallation) async -> Bool {
        guard credentials.secret(for: target.credential) != nil else { return false }
        return (try? await bindProvisioning(target, "").workspaceMembers()) != nil
    }

    /// Every configured Project's Linear project's teams (best effort, one board call each, errors
    /// ignored) — the re-install case, so the admin statement still names every team Yellowhammer needs.
    private func configuredProjectTeams(
        machine: MachineConfiguration, target: LinearInstallation
    ) async -> [BoardTeam] {
        guard let configuration = try? Configuration.load(directory: configurationDirectory) else { return [] }
        var teams: [BoardTeam] = []
        for project in configuration.projects {
            guard
                project.linearInstallationName == target.name,
                let scope = try? await bindProvisioning(target, project.linearProject).linearProject()
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
