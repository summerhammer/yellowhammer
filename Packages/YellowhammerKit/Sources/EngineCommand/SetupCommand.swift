import ArgumentParser
import Config
import Domain
import Engine
import Foundation

/// `yh setup`: authorizes Yellowhammer's Linear identity, requires the Operator identity immediately
/// after, provisions Linear per Project, registers local notification permission once, generates each
/// eligible Project's scheduled jobs (`--install-jobs`/`--export-jobs`/`--cron`), and warns about
/// routing entries with no resilience (routing/overview, OQ13).
///
/// Interactive by default: it prompts for whatever the options below did not already supply.
/// `--init` is non-interactive — it never prompts, and generates configuration from the options and the
/// spec's defaults. `--config <path>` is also non-interactive: it adopts a prepared configuration
/// directory instead of generating one. `--init` and `--config` are mutually exclusive.
public struct SetupCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Generate, adopt or verify machine and Project configuration, and provision Linear."
    )

    @Flag(name: .customLong("init"), help: "Generate configuration from options and defaults; never prompts.")
    public var initialize: Bool = false

    @Option(name: .customLong("config"), help: "Adopt a prepared configuration directory; never prompts.")
    public var config: String?

    @Flag(
        name: .customLong("print-choices"),
        help: "Print the Operator identity and team choices as JSON and exit; never prompts, writes nothing."
    )
    public var printChoices: Bool = false

    @Option(
        name: .customLong("linear-credential"),
        help: "Reference to the Linear Installation's stored tokens (default keychain:linear)."
    )
    public var linearCredential: String?

    @Option(
        name: .customLong("github-credential"), help: "Reference to the GitHub credential (default keychain:github)."
    )
    public var githubCredential: String?

    @Option(name: .customLong("cli"), help: "A declared CLI Adapter, as `name` or `name=executable`.")
    public var cli: [String] = []

    @Option(name: .customLong("route"), help: "The base Routing Table's one entry, as `cli/model/effort`.")
    public var route: String?

    @Option(name: .customLong("fallback"), help: "A fallback for --route, as `cli/model/effort`.")
    public var fallback: [String] = []

    @Option(name: .customLong("operator"), help: "The Operator identity's Linear user id.")
    public var operatorID: String?

    @Option(help: "The id of a Project to generate.")
    public var project: String?

    @Option(help: "The Project's display name; defaults to its id.")
    public var projectName: String?

    @Option(help: "An existing Linear project's id.")
    public var linearProject: String?

    @Option(name: .customLong("linear-team"), help: "A team key to create the Linear project in.")
    public var linearTeam: String?

    @Option(name: .customLong("spec-source"), help: "The Project's Spec Source path.")
    public var specSource: String?

    @Option(name: .customLong("night-start"), help: "The Project's Night start, as `HH:MM`; default 22:00.")
    public var nightStart: String?

    @Option(name: .customLong("night-end"), help: "The Project's Night end, as `HH:MM`; default 06:00.")
    public var nightEnd: String?

    @Option(name: .customLong("build-every-minutes"), help: "Minutes between build firings; default 15.")
    public var buildEveryMinutes: String?

    @Option(name: .customLong("repo"), help: "A Repo, as `name,role,path,check`.")
    public var repo: [String] = []

    @Flag(name: .customLong("install-jobs"), help: "Write and load every eligible Project's LaunchAgents.")
    public var installJobs: Bool = false

    @Option(
        name: .customLong("export-jobs"),
        help: "Write the scheduled jobs into this directory instead of loading them."
    )
    public var exportJobs: String?

    @Flag(name: .customLong("cron"), help: "With --export-jobs, write a crontab file instead of plists.")
    public var cron: Bool = false

    @Flag(
        name: .customLong("install-linear"),
        help: "Run only the Linear step (install, store, confirm), then the Operator identity choice, and exit."
    )
    public var installLinear: Bool = false

    @Option(
        name: .customLong("events"),
        help: "With --install-linear, emit one JSON object per line on stdout instead of prompting (\"json\")."
    )
    public var events: String?

    @Flag(
        name: .customLong("remote"),
        help: """
        With --install-linear: request approval from a Linear workspace admin through an approval \
        link, instead of signing in on this Mac.
        """
    )
    public var remote: Bool = false

    public init() {}

    public func validate() throws {
        _ = try SetupOptions(command: self)
    }

    public func run() async throws {
        // Line-buffered, not the block buffering stdio picks when stdout is not a terminal: under the
        // app (`--events json` over a pipe), or piped to a file or `tee`, `print` would otherwise hold
        // the remote approval link — and every progress event — until `yh` exits (P17.9).
        setvbuf(stdout, nil, _IOLBF, 0)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let options = try SetupOptions(command: self)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await Setup(
            options: options,
            configurationDirectory: configurationDirectory,
            output: { print($0) },
            console: RealSetupConsole(),
            credentials: KeychainSetupCredentialStore(),
            bindProvisioning: { machine, linearProjectID in
                BoardBinding.provisioning(machine: machine, linearProjectID: linearProjectID)
            },
            registerNotifications: Self.registerNotifications,
            homeDirectory: homeDirectory,
            yhExecutablePath: Self.yhExecutablePath(),
            setupTimePATH: ProcessInfo.processInfo.environment["PATH"],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
            launchAgents: LaunchctlLaunchAgentControl(),
            linearInstallSeams: .production(),
            linearInstallationStore: { reference in
                LinearInstallationStore(
                    reference: reference, keychain: KeychainCredentialStore(),
                    machineLock: MachineLock(fileURL: MachineLock.defaultFileURL(homeDirectory: homeDirectory))
                )
            },
            linearInstallEvents: { event in
                if let line = try? event.ndjsonLine() { print(line) }
            }
        ).run()
    }

    /// The absolute path to the `yh` binary currently running: the bundle's executable when running
    /// inside the app-embedded `Contents/MacOS/yh`, otherwise `argv[0]` resolved against the current
    /// directory.
    private static func yhExecutablePath() -> String {
        if let bundlePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path {
            return bundlePath
        }
        let argv0 = CommandLine.arguments[0]
        guard !argv0.hasPrefix("/") else { return argv0 }
        return URL(filePath: argv0, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    private static func registerNotifications() async -> NotificationRegistration {
        do {
            try await HeadlessAppLaunch.run(
                arguments: [NotificationPermissionRequest.flag], timeout: .seconds(150)
            )
            return .allowed
        } catch let error as HeadlessPostError {
            return .off(reason: error.description)
        } catch {
            return .off(reason: "\(error)")
        }
    }
}
