import Domain
import Foundation

// Steps 5-6 of removal: unload and delete the 3 LaunchAgents, then delete the 3 Act logs. Reuses
// ``ScheduledJob``'s own label/fileName/logPath construction (a throwaway job per Act, firings and
// yhExecutablePath unused) rather than re-deriving the naming scheme.

extension ProjectRemoval {
    private var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    /// Unloads (`bootout`, failure ignored — it may simply not be loaded) and deletes each Act's plist.
    /// A failed delete of a plist that exists is a step failure; a plist that is not there is fine.
    func removeLaunchAgents(projectID: ProjectID, failures: inout [String]) async {
        for act in Act.allCases {
            let job = ScheduledJob(projectID: projectID, act: act, yhExecutablePath: "", firings: [], pathValue: "")
            await removeLaunchAgent(job: job, failures: &failures)
        }
    }

    private func removeLaunchAgent(job: ScheduledJob, failures: inout [String]) async {
        try? await launchAgents.bootout(label: job.label)

        let plistURL = launchAgentsDirectory.appending(component: job.fileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            failures.append("could not remove \(job.fileName): \(error)") // glossary:ignore GL001
        }
    }

    /// Deletes each Act's log file, if present. A missing log is fine — never a failure.
    func removeLogs(projectID: ProjectID) async {
        for act in Act.allCases {
            let job = ScheduledJob(projectID: projectID, act: act, yhExecutablePath: "", firings: [], pathValue: "")
            let logURL = URL(fileURLWithPath: job.logPath(homeDirectory: homeDirectory.path(percentEncoded: false)))
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
