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

    @Option(help: "Only run this check (\(DoctorCheck.allCases.map(\.rawValue).joined(separator: ", "))).")
    public var check: String?

    @Flag(help: "Print findings as one JSON array instead of the human report (P17.7: the app's own read).")
    public var json: Bool = false

    public init() {}

    public func validate() throws {
        guard !yes || fix else {
            throw ValidationError("--yes requires --fix")
        }
        _ = try resolvedChecks()
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
                fix: fix, yes: yes, probe: probe, checks: try resolvedChecks(), projectFilter: projectFilter
            ),
            quiet: json
        )
        let findings = await doctor.run()
        if json {
            print(Self.encodeFindingsJSON(findings))
        }
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

    /// `--check <name>` narrows to one check (P17.7: the app polls `--check linear --json` on the
    /// Setup view's Linear step); absent, every check runs, as today.
    private func resolvedChecks() throws -> [DoctorCheck] {
        guard let check else { return DoctorCheck.allCases }
        guard let parsed = DoctorCheck(rawValue: check) else {
            let known = DoctorCheck.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--check must be one of: \(known)")
        }
        return [parsed]
    }

    /// One compact JSON array of `DoctorFindingRow`s — no `projectID`; a finding scoped to an App
    /// Installation also carries its name, workspace and Projects.
    static func encodeFindingsJSON(_ findings: [DoctorFinding]) -> String {
        DoctorFindingRow.encodeLine(findings.map { finding in
            DoctorFindingRow(
                check: finding.check.rawValue, subject: finding.subject,
                severity: severityString(finding.severity), message: finding.message,
                installation: finding.installation?.name, workspace: finding.installation?.workspace,
                workspaceName: finding.installation?.workspaceName,
                projects: finding.installation?.projects.map(\.rawValue)
            )
        })
    }

    private static func severityString(_ severity: DoctorSeverity) -> String {
        switch severity {
        case .pass: "pass"
        case .warning: "warning"
        case .failure: "failure"
        case .info: "info"
        }
    }

    /// Shared by `ValidateCommand`: the real seams, differing only in which checks and options apply.
    /// `quiet` suppresses the human report (`--json`): only findings return, printed by the caller.
    static func makeDoctor(
        configurationDirectory: URL, homeDirectory: URL, options: DoctorRunOptions, quiet: Bool = false
    ) -> Doctor {
        Doctor(
            configurationDirectory: configurationDirectory,
            homeDirectory: homeDirectory,
            output: quiet ? { _ in } : { print($0) },
            console: RealSetupConsole(),
            credentials: KeychainSetupCredentialStore(),
            bindProvisioning: { installation, linearProjectID in
                BoardBinding.provisioning(installation: installation, linearProjectID: linearProjectID)
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
