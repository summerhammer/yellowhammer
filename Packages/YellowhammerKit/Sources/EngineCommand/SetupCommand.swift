import ArgumentParser
import Config
import Domain
import Engine
import Foundation

/// `yh setup`: authorizes Yellowhammer's Linear identity, requires the Operator identity immediately
/// after, provisions Linear per Project, registers local notification permission once, and warns about
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

    @Option(name: .customLong("linear-client-id"), help: "The registered Linear OAuth application's client id.")
    public var linearClientID: String?

    @Option(
        name: .customLong("linear-credential"), help: "Reference to the Linear client secret (default keychain:linear)."
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

    @Flag(name: .customLong("linear-client-secret-stdin"), help: "Read the Linear client secret from stdin.")
    public var linearClientSecretStdin: Bool = false

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

    @Option(name: .customLong("repo"), help: "A Repo, as `name,role,path,check`.")
    public var repo: [String] = []

    public init() {}

    public func validate() throws {
        _ = try SetupOptions(command: self)
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let options = try SetupOptions(command: self)
        try await Setup(
            options: options,
            configurationDirectory: configurationDirectory,
            output: { print($0) },
            console: RealSetupConsole(),
            credentials: KeychainSetupCredentialStore(),
            readStandardInputLine: { readLine() },
            bindProvisioning: { machine, linearProjectID, secret in
                BoardBinding.provisioning(machine: machine, linearProjectID: linearProjectID, clientSecret: secret)
            },
            registerNotifications: Self.registerNotifications
        ).run()
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
