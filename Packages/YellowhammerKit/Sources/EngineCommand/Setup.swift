import Config
import Domain
import Foundation

/// `yh setup`'s orchestration, with every side effect injected as a seam: the Keychain, standard input,
/// the Board Port and the headless notification-permission launch. `SetupCommand.run()` builds the real
/// seams; tests inject fakes.
struct Setup {
    let options: SetupOptions
    let configurationDirectory: URL
    let output: (String) -> Void
    /// Never called in `--init` or `--config` mode.
    let console: any SetupConsole
    /// Presence-only: whether an Installation token pair exists in the Keychain — the Linear step's own
    /// "is it installed at all" gate. Never reads or stores a secret.
    let credentials: any SetupCredentialStore
    /// `linearProjectID` may be `""` for the workspace-level calls (`workspaceMembers()`, `teams()`,
    /// creation) — see ``BoardBinding/provisioning(installation:linearProjectID:credentials:homeDirectory:)``.
    let bindProvisioning: (LinearInstallation, String) -> any BoardProvisioning
    let registerNotifications: () async -> NotificationRegistration
    /// Where `--install-jobs` writes LaunchAgents (`<homeDirectory>/Library/LaunchAgents`) and every
    /// job's log path is expanded against. Tests inject a temp directory, never the real home.
    let homeDirectory: URL
    /// The resolved absolute path to the `yh` executable a generated job invokes.
    let yhExecutablePath: String
    /// The `PATH` the setup process itself ran with — the starting point ``ScheduledJob/composePATH``
    /// composes from. `nil` when unset in the environment.
    let setupTimePATH: String?
    /// Whether a candidate tool path names an existing executable file, injected so PATH resolution
    /// (`ProbeExecutable`) never touches the real filesystem in tests.
    let fileExists: (String) -> Bool
    /// `launchd`'s control surface for `--install-jobs`.
    let launchAgents: any LaunchAgentControl
    /// The Linear Board Connection browser flow's side effects (P17.6): port binding, the browser
    /// opener, the token transport. Tests inject stubs; `SetupCommand` wires the real ones.
    let linearInstallSeams: LinearInstallSeams
    /// Builds the Installation token store bound to a credential reference — a seam so tests use a
    /// throwaway Keychain reference rather than the machine's real one.
    let linearInstallationStore: (LinearInstallation) -> LinearInstallationStore
    /// `--events json`'s NDJSON sink; a no-op unless `options.eventsJSON`. Every call site decides
    /// whether to call this or ``output`` — never both, so `--events json` writes nothing else to stdout
    /// for the Linear step.
    let linearInstallEvents: @Sendable (LinearInstallEvent) -> Void

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    /// `.installLinear` still prompts (retry/cancel, y/n) unless `--events json` was given, which the
    /// app's own headless re-run always passes — every other non-interactive mode never prompts.
    var isInteractive: Bool {
        switch options.mode {
        case .interactive: true
        case .installLinear: !options.eventsJSON
        case .initialize, .config, .printChoices: false
        }
    }

    /// With `--config`, adopts a prepared configuration directory first. Authorizes Yellowhammer's
    /// Linear identity, requires the Operator identity immediately after, provisions Linear per
    /// Project, generates each eligible Project's scheduled jobs, registers local notification
    /// permission once, and warns about routing entries with no resilience. Throws with a clear message
    /// on any failure that stops setup; step 6's per-Project failures are printed and accumulate into
    /// the final throw instead.
    func run() async throws {
        if case .printChoices = options.mode {
            try await printChoices()
            return
        }
        if case .config(let source) = options.mode {
            try installPreparedConfiguration(from: source)
        }

        var machine = try loadOrCreateMachineFile()
        let request = try resolveLinearRequest(machine: machine)
        let selected: (members: [BoardMember], installation: LinearInstallation)?
        do {
            selected = try await authorizeLinear(request, machine: &machine)
        } catch {
            guard case .installLinear = options.mode else {
                // No Linear installation: the steps that need none still run (configuration validation,
                // notification registration, routing warnings) before the Linear failure is the final
                // error. Project file writing, provisioning and scheduled jobs need Linear (or its
                // provisioning) and are skipped.
                let configuration = try validateConfiguration()
                await reportNotifications()
                reportRoutingWarnings(configuration: configuration, machine: machine)
                throw SetupError(
                    "setup finished without a Linear installation; run yh setup --install-linear (\(error))"
                )
            }
            throw error
        }

        if case .installLinear = options.mode {
            // "Re-running the Linear step of setup": only this step and the Operator identity choice
            // (when none is configured) run; every Project's configuration is untouched.
            if let selected, selected.installation.operatorIdentity == nil {
                try setOperatorIdentity(
                    machine: &machine, installation: selected.installation, members: selected.members
                )
            }
            return
        }
        if let selected {
            try setOperatorIdentity(machine: &machine, installation: selected.installation, members: selected.members)
            let board = bindProvisioning(selected.installation, "")
            try await writeProjectsIfNeeded(machine: machine, installation: selected.installation, board: board)
        }

        let configuration = try validateConfiguration()
        let (provisioningFailedIDs, unfinishedProvisioning) = await provisionProjects(
            configuration: configuration, machine: machine
        )
        let jobsFailed = await handleScheduledJobs(
            configuration: configuration, machine: machine, provisioningFailedIDs: provisioningFailedIDs
        )
        await reportNotifications()
        reportRoutingWarnings(configuration: configuration, machine: machine)
        // The story's consolidated list, last: every unfinished provisioning step across every Project.
        reportUnfinishedProvisioning(unfinishedProvisioning)

        if !configuration.invalidProjects.isEmpty || !provisioningFailedIDs.isEmpty || jobsFailed {
            throw SetupError("setup finished with errors; see the output above")
        }
        output("Setup complete.")
    }
}
