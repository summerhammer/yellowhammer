import ArgumentParser
import CLIAdapters
import Config
import Domain
import Foundation

/// How `yh setup` was invoked: `--init` never prompts and generates from options and defaults;
/// `--config <path>` never prompts and adopts a prepared configuration directory; absent both, it is
/// interactive and prompts for whatever the options did not already supply.
enum SetupMode: Equatable {
    case initialize
    case config(URL)
    case interactive
    /// `--print-choices`: never prompts, writes no configuration file.
    case printChoices
    /// `--install-linear`: runs only the Linear step (install, store, confirm), then the Operator
    /// identity choice if none is configured, and exits — never touches Project files or jobs.
    case installLinear
    /// `--install-cli`: installs or repoints the `/usr/local/bin/yh` symlink and exits.
    case installCLI
    /// `--uninstall-cli`: removes `/usr/local/bin/yh` if it points to `yh` and exits.
    case uninstallCLI
    /// `--install-github`: runs only the GitHub step (capture, check, store the token), validates the
    /// token against the Repos, and exits — never touches Linear, Project files or jobs, and never creates
    /// `config.toml`.
    case installGitHub
    /// `--print-github`: never prompts, writes nothing; prints the GitHub credential report as one line.
    case printGitHub
}

/// The scheduled-jobs format `--export-jobs` writes.
enum JobsFormat: Equatable {
    case launchd
    case cron
}

/// What `yh setup` does with the scheduled jobs it generates for every eligible Project.
enum JobsRequest: Equatable {
    /// Neither `--install-jobs` nor `--export-jobs` was given; interactive mode still asks.
    case none
    case install
    case export(URL, format: JobsFormat)
}

/// `SetupCommand`'s raw options, parsed and cross-checked once. `SetupCommand.validate()` builds one
/// and discards it; `SetupCommand.run()` builds one and hands it to `Setup`. One source of truth for
/// every option-level ValidationError, so parsing and running can never disagree.
///
/// Credential references stay `nil` when not given on the command line — rather than eagerly resolved
/// to their default — so interactive mode can tell "given" from "default" and skip the prompt only for
/// the former.
struct SetupOptions {
    static let defaultGitHubCredential = MachineConfiguration.defaultGitHubCredential

    let mode: SetupMode
    /// `--events json`: emits `LinearInstallEvent` NDJSON on stdout instead of prompting or printing
    /// human text for the Linear step. Only meaningful with `--install-linear`; implies non-interactive.
    let eventsJSON: Bool
    /// `--remote` (roadmap P17.9): requests admin approval through the Code Relay instead of signing in
    /// on this Mac. Only meaningful with `--install-linear`.
    let remoteApproval: Bool
    /// `--board-connection`: the local name of the Linear Board Connection this run acts on (a re-connect
    /// target under `--install-linear`).
    let installation: String?
    /// `--board-connection-name`: the local name for a NEW Linear Board Connection. It never selects or
    /// renames an existing one, so it cannot be combined with `--board-connection`; when Linear approves a
    /// workspace already in the registry the name is discarded (and the run says so).
    let installationName: String?
    let githubCredential: CredentialReference?
    /// `--token-stdin`, `--from-gh`, `--replace` and `--github-repo`; only meaningful with `--install-github`
    /// or `--print-github`.
    let gitHub: GitHubStepOptions
    /// In `--cli` order.
    let cliAdapters: [CLIAdapterDeclaration]
    /// The base Routing Table's one entry (kind `*`, repo_role `*`), built from `--route`/`--fallback`.
    let route: RoutingEntry?
    let operatorID: BoardObjectID?
    let projectID: ProjectID?
    let projectName: String?
    let linearProjectID: String?
    let linearTeam: String?
    let specSource: String?
    /// The `[schedule]` from `--night-start`, `--night-end` and `--build-every-minutes`; omitted flags
    /// keep their defaults.
    let schedule: Schedule
    /// In `--repo` order.
    let repos: [RepoDeclaration]
    let jobs: JobsRequest

    init(command: SetupCommand) throws {
        mode = try Self.parseMode(command)
        eventsJSON = try Self.parseEventsJSON(command)
        remoteApproval = try Self.parseRemoteApproval(command)
        installation = try Self.parseInstallation(command.boardConnection)
        installationName = try Self.parseInstallationName(command)
        githubCredential = try Self.parseCredential(command.githubCredential, option: "--github-credential")
        gitHub = try GitHubStepOptions(command: command)
        operatorID = command.operatorID.map { BoardObjectID(rawValue: $0) }

        let (adapters, declaredNames) = try Self.parseCLIAdapters(command.cli)
        cliAdapters = adapters
        route = try Self.parseRoute(command: command, declaredNames: declaredNames)
        jobs = try Self.parseJobsRequest(command)

        try Self.validateProjectOptionScope(command)
        if let rawProject = command.project {
            let id = try Self.parseProjectID(rawProject)
            guard !(command.linearProject != nil && command.linearTeam != nil) else {
                throw ValidationError(
                    "--linear-project and --linear-team are mutually exclusive" // glossary:ignore GL001
                )
            }
            projectID = id
            projectName = command.projectName
            linearProjectID = command.linearProject
            linearTeam = command.linearTeam
            specSource = command.specSource
            schedule = try Self.parseSchedule(command)
            repos = try command.repo.map(Self.parseRepo)
        } else {
            projectID = nil
            projectName = nil
            linearProjectID = command.printChoices ? command.linearProject : nil
            linearTeam = nil
            specSource = nil
            schedule = Schedule()
            repos = []
        }
    }

    private static func parseMode(_ command: SetupCommand) throws -> SetupMode {
        if command.installCLI && command.uninstallCLI {
            throw ValidationError("--install-cli and --uninstall-cli are mutually exclusive")
        }
        if command.installCLI {
            try validateStandaloneCLIMode(command, flag: "--install-cli")
            return .installCLI
        }
        if command.uninstallCLI {
            try validateStandaloneCLIMode(command, flag: "--uninstall-cli")
            return .uninstallCLI
        }
        if command.installGitHub || command.printGitHub {
            try validateGitHubScope(command)
            return command.installGitHub ? .installGitHub : .printGitHub
        }
        try validateGitHubOptionsWithoutMode(command)
        if command.printChoices {
            try validatePrintChoicesScope(command)
            return .printChoices
        }
        if command.installLinear {
            guard !command.initialize, command.config == nil else {
                throw ValidationError("--install-linear cannot be combined with --init or --config")
            }
            return .installLinear
        }
        guard let configPath = command.config else {
            return command.initialize ? .initialize : .interactive
        }
        guard !command.initialize else {
            throw ValidationError("--config and --init are mutually exclusive")
        }
        let generating = !command.cli.isEmpty || command.route != nil
            || !command.fallback.isEmpty || command.project != nil
        guard !generating else {
            throw ValidationError(
                "--config cannot be combined with " // glossary:ignore GL001
                    + "--cli, --route, --fallback or --project" // glossary:ignore GL001
            )
        }
        return .config(URL(filePath: configPath, directoryHint: .isDirectory))
    }

    /// `--install-jobs` and `--export-jobs` are mutually exclusive; `--cron` requires `--export-jobs`.
    private static func parseJobsRequest(_ command: SetupCommand) throws -> JobsRequest {
        if let exportPath = command.exportJobs {
            guard !command.installJobs else {
                throw ValidationError("--install-jobs and --export-jobs are mutually exclusive")
            }
            let directory = URL(filePath: exportPath, directoryHint: .isDirectory)
            return .export(directory, format: command.cron ? .cron : .launchd)
        }
        guard !command.cron else {
            throw ValidationError("--cron requires --export-jobs")
        }
        return command.installJobs ? .install : .none
    }

    /// `--events json` is only meaningful with `--install-linear`; any other value is a ValidationError.
    private static func parseEventsJSON(_ command: SetupCommand) throws -> Bool {
        guard let events = command.events else { return false }
        guard events == "json" else {
            throw ValidationError("--events must be \"json\", got \"\(events)\"")
        }
        guard command.installLinear else {
            throw ValidationError("--events requires --install-linear")
        }
        return true
    }

    /// `--remote` is only meaningful with `--install-linear` (roadmap P17.9).
    private static func parseRemoteApproval(_ command: SetupCommand) throws -> Bool {
        guard command.remote else { return false }
        guard command.installLinear else {
            throw ValidationError("--remote requires --install-linear")
        }
        return true
    }

    private static func parseInstallation(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--board-connection must not be empty")
        }
        return raw
    }

    private static func parseCredential(_ raw: String?, option: String) throws -> CredentialReference? {
        guard let raw else { return nil }
        guard let reference = CredentialReference(raw) else {
            throw ValidationError("\(option) must not be empty")
        }
        return reference
    }

    private static func parseProjectID(_ raw: String) throws -> ProjectID {
        guard let id = ProjectID(rawValue: raw) else {
            throw ValidationError(
                "--project must be a valid Project id, got \"\(raw)\"" // glossary:ignore GL001
            )
        }
        return id
    }

    /// Every Project option without `--project` is a ValidationError.
    private static func validateProjectOptionScope(_ command: SetupCommand) throws {
        guard command.project == nil else { return }
        if command.printChoices && command.linearProject != nil {
            guard command.projectName == nil, command.linearTeam == nil,
                  command.specSource == nil, command.repo.isEmpty, command.nightStart == nil,
                  command.nightEnd == nil, command.buildEveryMinutes == nil
            else {
                throw ValidationError(
                    "--project-name, --linear-team, " // glossary:ignore GL001
                        + "--spec-source, --night-start, --night-end, --build-every-minutes " // glossary:ignore GL001
                        + "and --repo require --project" // glossary:ignore GL001
                )
            }
            return
        }
        guard command.projectName == nil, command.linearProject == nil, command.linearTeam == nil,
              command.specSource == nil, command.repo.isEmpty, command.nightStart == nil,
              command.nightEnd == nil, command.buildEveryMinutes == nil
        else {
            throw ValidationError(
                "--project-name, --linear-project, --linear-team, " // glossary:ignore GL001
                    + "--spec-source, --night-start, --night-end, --build-every-minutes " // glossary:ignore GL001
                    + "and --repo require --project" // glossary:ignore GL001
            )
        }
    }

    /// `--night-start`/`--night-end` as `HH:MM`, `--build-every-minutes` as an integer; omitted flags keep
    /// `Schedule()`'s defaults. Whether the window itself is acceptable is checked when the Project is
    /// written, before anything is created.
    private static func parseSchedule(_ command: SetupCommand) throws -> Schedule {
        var schedule = Schedule()
        if let raw = command.nightStart {
            schedule.nightStart = try parseTime(raw, option: "--night-start")
        }
        if let raw = command.nightEnd {
            schedule.nightEnd = try parseTime(raw, option: "--night-end")
        }
        if let raw = command.buildEveryMinutes {
            guard let minutes = Int(raw) else {
                throw ValidationError("--build-every-minutes must be an integer, got \"\(raw)\"")
            }
            schedule.buildEveryMinutes = minutes
        }
        return schedule
    }

    private static func parseTime(_ raw: String, option: String) throws -> TimeOfDay {
        guard let time = TimeOfDay(raw) else {
            throw ValidationError("\(option) must be \"HH:MM\", got \"\(raw)\"")
        }
        return time
    }

    /// `<name>[=<executable>]`, `name` checked against `CLIAdapterRegistry.allNames`.
    static func parseCLIAdapters(_ raw: [String]) throws -> ([CLIAdapterDeclaration], Set<String>) {
        var adapters: [CLIAdapterDeclaration] = []
        var names: Set<String> = []
        for entry in raw {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            guard CLIAdapterRegistry.allNames.contains(name) else {
                let known = CLIAdapterRegistry.allNames.joined(separator: ", ")
                throw ValidationError("--cli \"\(name)\" is not a registered CLI Adapter; known: \(known)")
            }
            adapters.append(CLIAdapterDeclaration(name: name, executable: parts.count > 1 ? String(parts[1]) : nil))
            names.insert(name)
        }
        return (adapters, names)
    }

    /// `--route` seeds the entry; `--fallback` requires it and becomes its fallbacks, in order. Every
    /// route's CLI must be among the declared `--cli` names, because the decoder refuses otherwise.
    private static func parseRoute(command: SetupCommand, declaredNames: Set<String>) throws -> RoutingEntry? {
        guard let rawRoute = command.route else {
            guard command.fallback.isEmpty else {
                throw ValidationError("--fallback requires --route")
            }
            return nil
        }
        return try makeRoutingEntry(route: rawRoute, fallbacks: command.fallback, declaredNames: declaredNames)
    }

    /// Shared by option parsing and the interactive routing prompt.
    static func makeRoutingEntry(
        route rawRoute: String, fallbacks rawFallbacks: [String], declaredNames: Set<String>
    ) throws -> RoutingEntry {
        let primary = try parseCLIModelEffort(rawRoute, option: "--route", declaredNames: declaredNames)
        let fallbacks = try rawFallbacks.map {
            try parseCLIModelEffort($0, option: "--fallback", declaredNames: declaredNames)
        }
        return RoutingEntry(route: primary, fallbacks: fallbacks)
    }

    static func parseCLIModelEffort(_ raw: String, option: String, declaredNames: Set<String>) throws -> Route {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let route = Route(cli: parts[0], model: parts[1], effort: parts[2]) else {
            throw ValidationError("\(option) must be \"cli/model/effort\", got \"\(raw)\"")
        }
        guard declaredNames.contains(route.cli) else {
            throw ValidationError("\(option) names CLI \"\(route.cli)\", which was not declared with --cli")
        }
        return route
    }

    /// `name,role,path,check`, split on the first three commas only, so `check` may contain commas.
    static func parseRepo(_ raw: String) throws -> RepoDeclaration {
        let parts = raw.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError("--repo must be \"name,role,path,check\", got \"\(raw)\"")
        }
        let (name, role, path, check) = (parts[0], parts[1], parts[2], parts[3])
        return RepoDeclaration(
            name: name, path: path, role: RepoRole(rawValue: role), check: check == "none" ? .none : .command(check)
        )
    }
}

extension SetupOptions {
    private static func parseInstallationName(_ command: SetupCommand) throws -> String? {
        guard let raw = command.boardConnectionName else { return nil }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--board-connection-name must not be empty")
        }
        guard command.boardConnection == nil else {
            throw ValidationError(
                "--board-connection-name names a new Board Connection and cannot be combined with "
                    + "--board-connection, which selects an existing one"
            )
        }
        return raw
    }
}
