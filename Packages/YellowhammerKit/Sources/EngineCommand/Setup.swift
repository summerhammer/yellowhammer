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
    let credentials: any SetupCredentialStore
    let readStandardInputLine: () -> String?
    /// `linearProjectID` may be `""` for the workspace-level calls (`workspaceMembers()`, `teams()`,
    /// creation) — see ``BoardBinding/provisioning(machine:linearProjectID:clientSecret:)``.
    let bindProvisioning: (MachineConfiguration, String, String) throws -> any BoardProvisioning
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

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    var isInteractive: Bool { options.mode == .interactive }

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
        let secret = try resolveLinearSecret(machine: machine)
        let board = try bindWorkspaceBoard(machine: machine, secret: secret)
        let members = try await authorize(board: board)
        try setOperatorIdentity(machine: &machine, members: members)

        try await writeProjectsIfNeeded(machine: machine, secret: secret, board: board)

        let configuration = try validateConfiguration()
        let provisioningFailedIDs = await provisionProjects(
            configuration: configuration, machine: machine, secret: secret
        )
        let jobsFailed = await handleScheduledJobs(
            configuration: configuration, machine: machine, provisioningFailedIDs: provisioningFailedIDs
        )
        await reportNotifications()
        reportRoutingWarnings(configuration: configuration, machine: machine)

        if !configuration.invalidProjects.isEmpty || !provisioningFailedIDs.isEmpty || jobsFailed {
            throw SetupError("setup finished with errors; see the output above")
        }
        output("Setup complete.")
    }
}
