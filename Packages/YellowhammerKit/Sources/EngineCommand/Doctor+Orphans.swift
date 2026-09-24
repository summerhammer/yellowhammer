import Config
import Domain
import Foundation

extension Doctor {
    /// Check 6: a LaunchAgent plist named `com.summerhammer.yellowhammer.<project>.<act>.plist` whose
    /// Project id has no `<id>.toml` under `projects/` (valid or invalid — an invalid Project file is
    /// misconfigured, not removed) is orphaned: a manually deleted Project's leftover schedule.
    /// Unrelated files are ignored. With `--fix`, offers to unload and delete every orphan found; a
    /// removed orphan's finding becomes a pass.
    func runOrphansCheck(configuration: Configuration) async -> [DoctorFinding] {
        let orphanLabels = findOrphanLabels()
        guard fix, !orphanLabels.isEmpty else {
            return orphanLabels.map {
                finding(.orphans, subject: $0, .failure, "\($0).plist is orphaned: no configured Project")
            }
        }

        guard yes || confirmRemoval(count: orphanLabels.count) else {
            output("nothing removed")
            return orphanLabels.map {
                finding(.orphans, subject: $0, .failure, "\($0).plist is orphaned: no configured Project")
            }
        }

        var findings: [DoctorFinding] = []
        for label in orphanLabels {
            do {
                try await removeOrphan(label: label)
                findings.append(
                    finding(.orphans, subject: label, .pass, "removed orphaned LaunchAgent \(label).plist")
                )
            } catch {
                findings.append(
                    finding(.orphans, subject: label, .failure, "could not remove \(label).plist: \(error)")
                )
            }
        }
        return findings
    }

    /// Every orphaned label's plist file, found under `launchAgentsDirectory`, sorted.
    private func findOrphanLabels() -> [String] {
        let directory = launchAgentsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )) ?? []
        var orphans: [String] = []
        let prefix = "com.summerhammer.yellowhammer."
        for name in names {
            guard name.hasSuffix(".plist"), name.hasPrefix(prefix) else { continue }
            let label = String(name.dropLast(".plist".count))
            let rest = label.dropFirst(prefix.count)
            guard let act = Act.allCases.first(where: { rest.hasSuffix(".\($0.rawValue)") }) else { continue }
            let projectID = String(rest.dropLast(act.rawValue.count + 1))
            guard !projectID.isEmpty else { continue }
            let projectFile = configurationDirectory.appending(
                components: "projects", "\(projectID).toml", directoryHint: .notDirectory
            )
            guard !FileManager.default.fileExists(atPath: projectFile.path(percentEncoded: false)) else { continue }
            orphans.append(label)
        }
        return orphans.sorted()
    }

    private func confirmRemoval(count: Int) -> Bool {
        guard let answer = console.ask("Unload and remove \(count) orphaned LaunchAgent(s)? [y/N] ") else {
            return false
        }
        let normalized = answer.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "y" || normalized == "yes"
    }

    /// A failed `bootout` is ignored (the orphan may simply not be loaded); a failed delete is not.
    private func removeOrphan(label: String) async throws {
        try? await launchAgents.bootout(label: label)
        let plistURL = launchAgentsDirectory.appending(component: "\(label).plist", directoryHint: .notDirectory)
        try FileManager.default.removeItem(at: plistURL)
    }
}
