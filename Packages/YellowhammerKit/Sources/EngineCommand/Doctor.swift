import Config
import Domain
import Foundation
import Repositories

/// `yh doctor`'s (and `yh validate`'s) orchestration, with every side effect injected as a seam,
/// mirroring ``Setup``. `checks` is the ordered subset of ``DoctorCheck`` this run performs:
/// `yh doctor` runs all of them, `yh validate` runs only ``DoctorCheck/configuration``.
struct Doctor {
    let configurationDirectory: URL
    let homeDirectory: URL
    let output: (String) -> Void
    let console: any SetupConsole
    /// Whether an Installation token pair exists in the Keychain (Check 4's first criterion: presence
    /// only), and the GitHub token itself, which the GitHub check reads to call GitHub with. Never stores.
    let credentials: any SetupCredentialStore
    /// `linearProjectID` is `""` for the workspace-scoped reads (identity, members) and the Project's own
    /// Linear project for the board-membership check.
    let bindProvisioning: (LinearInstallation, String) -> any BoardProvisioning
    let launchAgents: any LaunchAgentControl
    let git: GitRunner
    /// Reads the GitHub token (through `credentials`) and asks GitHub whether it can push to each working
    /// Repo. Read-only against GitHub.
    let gitHub: GitHubCredentialValidation
    /// Runs `yh probe <name>` for one declared CLI. Real seam: `ProbeCommand.parse([name]).run(...)`.
    let runProbe: (String) async -> Void
    let fix: Bool
    let yes: Bool
    let probe: Bool
    let checks: [DoctorCheck]
    /// Only report this Project's findings, plus machine-scoped ones, when set.
    let projectFilter: ProjectID?
    var commandLineToolLink: CommandLineToolLink = CommandLineToolLink()
    var runningExecutablePath: String = CommandLineToolLink.runningExecutablePath()

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    /// Runs every requested check in order, printing each finding and a final summary line, and
    /// returns every finding gathered (tests inspect this directly; `DoctorCommand`/`ValidateCommand`
    /// use it to decide the exit code).
    @discardableResult
    func run() async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        guard let configuration = runConfigurationCheck(into: &findings) else {
            let kept = keptFindings(findings)
            printSummary(kept)
            return kept
        }

        if let projectFilter, !matchesKnownProject(projectFilter, configuration: configuration) {
            findings.append(finding(
                .configuration, subject: projectFilter.rawValue, .failure,
                "no Project \(projectFilter.rawValue) in configuration" // glossary:ignore GL001
            ))
        }

        if checks.contains(.probes) {
            findings += await runProbesCheck(machine: configuration.machine)
        }
        if checks.contains(.git) {
            findings += await runGitCheck(configuration: configuration)
        }
        if checks.contains(.linear) {
            findings += await runLinearCheck(configuration: configuration)
        }
        if checks.contains(.github) {
            findings += await runGitHubCheck(configuration: configuration)
        }
        if checks.contains(.launchd) {
            findings += await runLaunchdCheck(configuration: configuration)
        }
        if checks.contains(.orphans) {
            findings += await runOrphansCheck(configuration: configuration)
        }

        let kept = keptFindings(findings)
        printSummary(kept)
        return kept
    }

    /// `--project` matches a valid Project by id, or an invalid one by id when known or by its
    /// file's last path component (`<id>.toml`) otherwise — mirrors `Status.matchesFilter`.
    private func matchesKnownProject(_ id: ProjectID, configuration: Configuration) -> Bool {
        if configuration.projects.contains(where: { $0.id == id }) {
            return true
        }
        return configuration.invalidProjects.contains { invalid in
            if let invalidID = invalid.id {
                return invalidID == id
            }
            return (invalid.file as NSString).lastPathComponent == "\(id.rawValue).toml"
        }
    }

    /// Keeps only machine-scoped findings, findings scoped to `projectFilter`, and findings of an
    /// installation or Code Hosting Connection that serves it, when set.
    private func keptFindings(_ findings: [DoctorFinding]) -> [DoctorFinding] {
        guard let projectFilter else { return findings }
        return findings.filter { finding in
            if finding.projectID == nil, finding.installation == nil, finding.codeHosting == nil { return true }
            return finding.projectID == projectFilter
                || finding.installation?.projects.contains(projectFilter) == true
                || finding.codeHosting?.projects.contains(projectFilter) == true
        }
    }

    private func printSummary(_ findings: [DoctorFinding]) {
        for finding in findings {
            output("[\(finding.severity.tag)] \(finding.check.rawValue): \(finding.message)")
        }
        let failed = findings.filter { $0.severity == .failure }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        output("\(failed) failed, \(warnings) warnings")
    }

    func finding(
        _ check: DoctorCheck, subject: String, _ severity: DoctorSeverity, _ message: String,
        project: ProjectID? = nil, installation: DoctorInstallationScope? = nil,
        codeHosting: DoctorCodeHostingScope? = nil
    ) -> DoctorFinding {
        DoctorFinding(
            check: check, subject: subject, severity: severity, message: message, projectID: project,
            installation: installation, codeHosting: codeHosting
        )
    }
}
