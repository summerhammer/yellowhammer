import ArgumentParser
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
    /// The Keychain. The Linear step uses it for presence only (its own "is it installed at all" gate); the
    /// GitHub step reads the token to call GitHub with it, and stores one the Operator supplied.
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
    /// Asks GitHub whether the token can push to each working Repo (the GitHub step).
    let gitHub: GitHubCredentialValidation
    /// Imports a token from the GitHub CLI (`gh auth token`). Never called unless the Operator accepts it
    /// or passes `--from-gh`.
    let importGitHubToken: @Sendable () async -> GitHubTokenImport
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
    var commandLineToolLink: CommandLineToolLink = CommandLineToolLink()
    var isTTY: () -> Bool = { isatty(STDIN_FILENO) != 0 }
    var runSudo: (String) throws -> Int32 = Setup.defaultRunSudo

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    /// `.installLinear` still prompts (retry/cancel, y/n) unless `--events json` was given, which the
    /// app's own headless re-run always passes — every other non-interactive mode never prompts.
    var isInteractive: Bool {
        switch options.mode {
        case .interactive: true
        case .installLinear: !options.eventsJSON
        case .installGitHub: options.gitHubTokenSource == .prompt
        case .initialize, .config, .printChoices, .installCLI, .uninstallCLI, .printGitHub: false
        }
    }

    /// With `--config`, adopts a prepared configuration directory first. Authorizes Yellowhammer's
    /// Linear identity, requires the Operator identity immediately after, provisions Linear per
    /// Project, generates each eligible Project's scheduled jobs, registers local notification
    /// permission once, and warns about routing entries with no resilience. Throws with a clear message
    /// on any failure that stops setup; step 6's per-Project failures are printed and accumulate into
    /// the final throw instead.
    func run() async throws {
        if try await runStandaloneMode() { return }
        if case .config(let source) = options.mode {
            try installPreparedConfiguration(from: source)
        }

        var machine = try loadOrCreateMachineFile()
        let codeHostingConnection = try await selectCodeHostingConnection(machine: &machine)
        let request = try resolveLinearRequest(machine: machine)
        let selected: (members: [BoardMember], installation: LinearInstallation)?
        do {
            selected = try await authorizeLinear(request, machine: &machine)
        } catch {
            guard case .installLinear = options.mode else {
                try await finishWithoutBoardConnection(machine: machine, error: error)
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
            try await writeProjectsIfNeeded(
                machine: machine, installation: selected.installation, codeHostingConnection: codeHostingConnection,
                board: board
            )
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

    /// Runs the modes that do not touch Linear or the Projects; returns whether one of them ran.
    private func runStandaloneMode() async throws -> Bool {
        switch options.mode {
        case .printChoices:
            try await printChoices()
        case .installCLI:
            try runInstallCLI()
        case .uninstallCLI:
            try runUninstallCLI()
        case .printGitHub:
            await printGitHub()
        case .installGitHub:
            try await installGitHub()
        case .interactive, .initialize, .config, .installLinear:
            return false
        }
        return true
    }

    /// No Linear installation: the steps that need none still run (configuration validation,
    /// notification registration, routing warnings) before the Linear failure is the final
    /// error. Project file writing, provisioning and scheduled jobs need Linear (or its
    /// provisioning) and are skipped.
    private func finishWithoutBoardConnection(machine: MachineConfiguration, error: any Error) async throws -> Never {
        let configuration = try validateConfiguration()
        await reportNotifications()
        reportRoutingWarnings(configuration: configuration, machine: machine)
        throw SetupError(
            "setup finished without a Board Connection; run yh setup --install-linear (\(error))"
        )
    }

    func runInstallCLI() throws {
        let state = commandLineToolLink.inspect(runningExecutable: yhExecutablePath)
        switch state {
        case .installed:
            output("Command Line Tool symlink is already installed at \(commandLineToolLink.linkPath)")
            return
        case .mismatched(let target) where target == commandLineToolLink.linkPath:
            throw SetupError("refusing to replace non-symlink file at \(commandLineToolLink.linkPath)")
        case .notInstalled, .dangling, .mismatched:
            if commandLineToolLink.isParentDirectoryWritable {
                do {
                    try commandLineToolLink.install(target: yhExecutablePath)
                    output(
                        "Installed Command Line Tool symlink at "
                            + "\(commandLineToolLink.linkPath) -> \(yhExecutablePath)"
                    )
                } catch {
                    throw SetupError("could not install Command Line Tool symlink: \(error)")
                }
            } else {
                let privilegedCommand = commandLineToolLink.privilegedInstallCommand(target: yhExecutablePath)
                if isTTY() {
                    let status = try runSudo(privilegedCommand)
                    guard status == 0 else {
                        throw SetupError("sudo failed with exit status \(status)")
                    }
                    output(
                        "Installed Command Line Tool symlink at "
                            + "\(commandLineToolLink.linkPath) -> \(yhExecutablePath)"
                    )
                } else {
                    output("sudo /bin/sh -c \(CommandLineToolLink.shellQuote(privilegedCommand))")
                    throw ExitCode(1)
                }
            }
        }
    }

    func runUninstallCLI() throws {
        let state = commandLineToolLink.inspect(runningExecutable: yhExecutablePath)
        if case .notInstalled = state {
            output("Command Line Tool symlink is not installed at \(commandLineToolLink.linkPath)")
            return
        }
        do {
            try commandLineToolLink.checkUninstallEligibility()
        } catch {
            throw SetupError("\(error)")
        }
        if commandLineToolLink.isParentDirectoryWritable {
            do {
                try commandLineToolLink.uninstall()
                output("Removed Command Line Tool symlink at \(commandLineToolLink.linkPath)")
            } catch {
                throw SetupError("could not remove Command Line Tool symlink: \(error)")
            }
        } else {
            let privilegedCommand = commandLineToolLink.privilegedUninstallCommand()
            if isTTY() {
                let status = try runSudo(privilegedCommand)
                guard status == 0 else {
                    throw SetupError("sudo failed with exit status \(status)")
                }
                output("Removed Command Line Tool symlink at \(commandLineToolLink.linkPath)")
            } else {
                output("sudo /bin/sh -c \(CommandLineToolLink.shellQuote(privilegedCommand))")
                throw ExitCode(1)
            }
        }
    }

    static func defaultRunSudo(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sudo")
        process.arguments = ["/bin/sh", "-c", command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
