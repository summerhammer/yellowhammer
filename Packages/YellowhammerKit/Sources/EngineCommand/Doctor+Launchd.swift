import Config
import Domain
import Foundation

extension Doctor {
    /// Check 5: for every valid Project and each Act, whether its LaunchAgent is installed and loaded,
    /// and whether its `StartCalendarInterval` matches the firings the Project's `[schedule]` implies
    /// (`Schedule.firings(staggerIndex:)`). A missing, unloaded or out-of-date plist is a warning, never a
    /// failure — the Operator may unload jobs to pause a Project (paused, not removed). With `--fix`, an
    /// out-of-date Project's installed jobs are regenerated (see `Doctor+LaunchdSchedule.swift`).
    func runLaunchdCheck(configuration: Configuration) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        // The stagger index is a Project's position among ALL configured Projects (sorted by id), exactly
        // as setup computes it, whatever `--project` narrows the report to.
        let allIDs = configuration.projects.map(\.id)
        for project in configuration.projects {
            guard let staggerIndex = allIDs.firstIndex(of: project.id) else { continue }
            findings += await launchdFindings(
                project: project, staggerIndex: staggerIndex, machine: configuration.machine
            )
        }
        findings.append(commandLineToolFinding())
        return findings
    }

    /// One Act's findings. The missing and not-loaded warnings, and the pass for an installed and loaded
    /// job whose schedule matches, read as they always have.
    func launchdFindings(for state: LaunchdJobState, regenerated: Bool) -> [DoctorFinding] {
        let label = state.label
        let subject = "Project \(state.projectID.rawValue) \(state.act.rawValue)"
        guard state.installed else {
            return [finding(
                .launchd, subject: label, .warning,
                "\(subject) LaunchAgent \(label) is not installed; run `yh setup --install-jobs`",
                project: state.projectID
            )]
        }
        var findings: [DoctorFinding] = []
        if !state.loaded {
            findings.append(finding(
                .launchd, subject: label, .warning,
                "\(subject) LaunchAgent \(label) is installed but not loaded", // glossary:ignore GL001
                project: state.projectID
            ))
        }
        if let difference = state.difference {
            findings.append(finding(
                .launchd, subject: label, .warning,
                "\(subject) LaunchAgent \(label) differs from its [schedule]: \(difference); "
                    + "run `yh doctor --fix`",
                project: state.projectID
            ))
        } else if regenerated {
            findings.append(finding(
                .launchd, subject: label, .pass,
                "\(subject) LaunchAgent \(label) regenerated to match its [schedule]"
                    + (state.loaded ? "; installed and loaded" : "; left unloaded"),
                project: state.projectID
            ))
        } else if state.loaded {
            findings.append(finding(
                .launchd, subject: label, .pass, "\(subject) LaunchAgent \(label) is installed and loaded",
                project: state.projectID
            ))
        }
        return findings
    }

    private func commandLineToolFinding() -> DoctorFinding {
        let subject = commandLineToolLink.linkPath
        let state = commandLineToolLink.inspect(runningExecutable: runningExecutablePath)
        switch state {
        case .installed:
            return finding(
                .launchd, subject: subject, .pass,
                "Command Line Tool symlink \(subject) resolves to running yh"
            )
        case .notInstalled:
            return finding(
                .launchd, subject: subject, .info,
                "Command Line Tool is not installed at \(subject); "
                    + "install via Yellowhammer → Install Command Line Tool… or yh setup --install-cli"
            )
        case .dangling(let target):
            return repointedOrWarning(
                subject: subject, canRepoint: fix,
                warning: "Command Line Tool symlink \(subject) is dangling (target \(target) does not exist)"
            )
        case .mismatched(let target):
            return repointedOrWarning(
                subject: subject, canRepoint: fix && commandLineToolLink.isSymlink,
                warning: "Command Line Tool symlink \(subject) resolves to \(target), "
                    + "not running yh (\(runningExecutablePath))"
            )
        }
    }

    /// With `--fix`, repoints a dangling or mismatched symlink; otherwise (or when the repoint cannot
    /// be done) reports `warning`, printing the manual commands when the parent directory is read-only.
    private func repointedOrWarning(subject: String, canRepoint: Bool, warning: String) -> DoctorFinding {
        guard canRepoint else {
            return finding(.launchd, subject: subject, .warning, warning)
        }
        guard commandLineToolLink.isParentDirectoryWritable else {
            output("sudo ln -sfh '\(runningExecutablePath)' \(subject)")
            output("sudo chmod -h 0755 \(subject)")
            output("or update via Yellowhammer → Update Command Line Tool…")
            return finding(.launchd, subject: subject, .warning, warning)
        }
        do {
            try commandLineToolLink.install(target: runningExecutablePath)
            return finding(
                .launchd, subject: subject, .pass,
                "repointed Command Line Tool symlink \(subject) -> \(runningExecutablePath)"
            )
        } catch {
            return finding(.launchd, subject: subject, .warning, warning)
        }
    }
}
