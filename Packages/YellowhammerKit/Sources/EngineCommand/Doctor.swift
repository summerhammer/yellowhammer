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
    let credentials: any SetupCredentialStore
    /// `linearProjectID` is always `""`: doctor only ever calls workspace-scoped methods.
    let bindProvisioning: (MachineConfiguration, String, String) throws -> any BoardProvisioning
    let launchAgents: any LaunchAgentControl
    let git: GitRunner
    /// Runs `yh probe <name>` for one declared CLI. Real seam: `ProbeCommand.parse([name]).run(...)`.
    let runProbe: (String) async -> Void
    let fix: Bool
    let yes: Bool
    let probe: Bool
    let checks: [DoctorCheck]

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
            printSummary(findings)
            return findings
        }

        if checks.contains(.probes) {
            findings += await runProbesCheck(machine: configuration.machine)
        }
        if checks.contains(.git) {
            findings += await runGitCheck(configuration: configuration)
        }
        if checks.contains(.linear) {
            findings += await runLinearCheck(machine: configuration.machine)
        }
        if checks.contains(.launchd) {
            findings += await runLaunchdCheck(configuration: configuration)
        }
        if checks.contains(.orphans) {
            findings += await runOrphansCheck(configuration: configuration)
        }

        printSummary(findings)
        return findings
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
        _ check: DoctorCheck, subject: String, _ severity: DoctorSeverity, _ message: String
    ) -> DoctorFinding {
        DoctorFinding(check: check, subject: subject, severity: severity, message: message)
    }
}
