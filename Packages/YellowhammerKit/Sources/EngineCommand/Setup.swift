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

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    var isInteractive: Bool { options.mode == .interactive }

    /// With `--config`, adopts a prepared configuration directory first. Authorizes Yellowhammer's
    /// Linear identity, requires the Operator identity immediately after, provisions Linear per
    /// Project, registers local notification permission once, and warns about routing entries with no
    /// resilience. Throws with a clear message on any failure that stops setup; step 6's per-Project
    /// failures are printed and accumulate into the final throw instead.
    func run() async throws {
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
        let provisioningFailed = await provisionProjects(configuration: configuration, machine: machine, secret: secret)
        await reportNotifications()
        reportRoutingWarnings(configuration: configuration, machine: machine)

        if !configuration.invalidProjects.isEmpty || provisioningFailed {
            throw SetupError("setup finished with errors; see the output above")
        }
        output("Setup complete.")
    }
}
