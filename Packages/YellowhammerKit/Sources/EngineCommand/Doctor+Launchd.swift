import Config
import Domain
import Foundation

extension Doctor {
    /// Check 5: for every valid Project and each Act, whether its LaunchAgent is installed and loaded.
    /// A missing or unloaded plist is a warning, never a failure — the Operator may unload jobs to
    /// pause a Project (paused, not removed).
    func runLaunchdCheck(configuration: Configuration) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        for project in configuration.projects {
            for act in Act.allCases {
                findings.append(await launchdFinding(projectID: project.id, act: act))
            }
        }
        findings.append(commandLineToolFinding())
        return findings
    }

    private func launchdFinding(projectID: ProjectID, act: Act) async -> DoctorFinding {
        let label = "dev.yellowhammer.\(projectID.rawValue).\(act.rawValue)"
        let subject = "Project \(projectID.rawValue) \(act.rawValue)"
        let plistURL = launchAgentsDirectory.appending(component: "\(label).plist", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) else {
            return finding(
                .launchd, subject: label, .warning,
                "\(subject) LaunchAgent \(label) is not installed; run `yh setup --install-jobs`",
                project: projectID
            )
        }
        guard await launchAgents.isLoaded(label: label) else {
            return finding(
                .launchd, subject: label, .warning,
                "\(subject) LaunchAgent \(label) is installed but not loaded", // glossary:ignore GL001
                project: projectID
            )
        }
        return finding(
            .launchd, subject: label, .pass, "\(subject) LaunchAgent \(label) is installed and loaded",
            project: projectID
        )
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
                "Command Line Tool is not installed at \(subject); install via Yellowhammer → Install Command Line Tool… or yh setup --install-cli"
            )
        case .dangling(let target):
            if fix {
                if commandLineToolLink.isParentDirectoryWritable {
                    do {
                        try commandLineToolLink.install(target: runningExecutablePath)
                        return finding(
                            .launchd, subject: subject, .pass,
                            "repointed Command Line Tool symlink \(subject) -> \(runningExecutablePath)"
                        )
                    } catch {
                        return finding(
                            .launchd, subject: subject, .warning,
                            "Command Line Tool symlink \(subject) is dangling (target \(target) does not exist)"
                        )
                    }
                } else {
                    output("sudo ln -sfh '\(runningExecutablePath)' \(subject)")
                    output("sudo chmod -h 0755 \(subject)")
                    output("or update via Yellowhammer → Update Command Line Tool…")
                    return finding(
                        .launchd, subject: subject, .warning,
                        "Command Line Tool symlink \(subject) is dangling (target \(target) does not exist)"
                    )
                }
            } else {
                return finding(
                    .launchd, subject: subject, .warning,
                    "Command Line Tool symlink \(subject) is dangling (target \(target) does not exist)"
                )
            }
        case .mismatched(let target):
            if fix && commandLineToolLink.isSymlink {
                if commandLineToolLink.isParentDirectoryWritable {
                    do {
                        try commandLineToolLink.install(target: runningExecutablePath)
                        return finding(
                            .launchd, subject: subject, .pass,
                            "repointed Command Line Tool symlink \(subject) -> \(runningExecutablePath)"
                        )
                    } catch {
                        return finding(
                            .launchd, subject: subject, .warning,
                            "Command Line Tool symlink \(subject) resolves to \(target), not running yh (\(runningExecutablePath))"
                        )
                    }
                } else {
                    output("sudo ln -sfh '\(runningExecutablePath)' \(subject)")
                    output("sudo chmod -h 0755 \(subject)")
                    output("or update via Yellowhammer → Update Command Line Tool…")
                    return finding(
                        .launchd, subject: subject, .warning,
                        "Command Line Tool symlink \(subject) resolves to \(target), not running yh (\(runningExecutablePath))"
                    )
                }
            } else {
                return finding(
                    .launchd, subject: subject, .warning,
                    "Command Line Tool symlink \(subject) resolves to \(target), not running yh (\(runningExecutablePath))"
                )
            }
        }
    }
}

