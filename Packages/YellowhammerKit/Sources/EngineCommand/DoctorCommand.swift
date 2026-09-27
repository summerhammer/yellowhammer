import ArgumentParser
import Config
import Domain
import Foundation
import Repositories

/// `yh doctor`: checks configuration, agent CLI probe eligibility, git, Linear authorization and the
/// Operator identity, installed LaunchAgents, and orphaned LaunchAgents left behind by a manually
/// deleted Project (spec: object-guide Project lifecycle, OQ52(1)). `--project` narrows the report to
/// one Project's findings plus the machine-scoped ones (spec risks.md OQ12 "Surface 3").
public struct DoctorCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check configuration, Linear authorization, git, probes and LaunchAgents."
    )

    @Flag(help: "Unload and remove orphaned LaunchAgents, after confirmation.")
    public var fix: Bool = false

    @Flag(help: "With --fix, remove orphaned LaunchAgents without asking for confirmation.")
    public var yes: Bool = false

    @Flag(help: "Probe every declared CLI Adapter before checking its route-target eligibility.")
    public var probe: Bool = false

    @Option(help: "Only report this Project and machine-wide findings.")
    public var project: String?

    public init() {}

    public func validate() throws {
        guard !yes || fix else {
            throw ValidationError("--yes requires --fix")
        }
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let projectFilter = try resolvedProjectFilter()
        let doctor = Self.makeDoctor(
            configurationDirectory: configurationDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            options: DoctorRunOptions(
                fix: fix, yes: yes, probe: probe, checks: DoctorCheck.allCases, projectFilter: projectFilter
            )
        )
        let findings = await doctor.run()
        if findings.contains(where: { $0.severity == .failure }) {
            throw ExitCode(1)
        }
    }

    private func resolvedProjectFilter() throws -> ProjectID? {
        guard let project else { return nil }
        guard let id = ProjectID(rawValue: project) else {
            throw ValidationError("--project \(project) is not a valid Project id")
        }
        return id
    }

    /// Shared by `ValidateCommand`: the real seams, differing only in which checks and options apply.
    static func makeDoctor(configurationDirectory: URL, homeDirectory: URL, options: DoctorRunOptions) -> Doctor {
        Doctor(
            configurationDirectory: configurationDirectory,
            homeDirectory: homeDirectory,
            output: { print($0) },
            console: RealSetupConsole(),
            credentials: KeychainSetupCredentialStore(),
            bindProvisioning: { machine, linearProjectID in
                BoardBinding.provisioning(machine: machine, linearProjectID: linearProjectID)
            },
            launchAgents: LaunchctlLaunchAgentControl(),
            git: GitRunner(),
            runProbe: { name in
                try? await ProbeCommand.parse([name]).run(configurationDirectory: configurationDirectory)
            },
            fix: options.fix, yes: options.yes, probe: options.probe, checks: options.checks,
            projectFilter: options.projectFilter
        )
    }
}

/// `--fix`/`--yes`/`--probe`, which checks to run, and the `--project` filter, grouped to keep
/// `makeDoctor` within SwiftLint's parameter-count limit.
struct DoctorRunOptions {
    let fix: Bool
    let yes: Bool
    let probe: Bool
    let checks: [DoctorCheck]
    let projectFilter: ProjectID?
}
