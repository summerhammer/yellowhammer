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
        return findings
    }

    private func launchdFinding(projectID: ProjectID, act: Act) async -> DoctorFinding {
        let label = "com.summerhammer.yellowhammer.\(projectID.rawValue).\(act.rawValue)"
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
}
