import Config
import Domain
import Foundation
import Journal

extension LandingSnapshot {
    /// Reads the landing screen of every configured Project, as of `asOf`.
    ///
    /// Only `configuration.projects` is read. A Project file refused at load is not a configured
    /// Project: it is never listed, and its Journal is never opened (OQ79). Projects keep the loader's
    /// order, and each Project's Repos keep their `[repos]` declared order.
    ///
    /// Each Project is read from its own Journal alone (R20; ADR-002). The Journal is found by that
    /// Project's id, opened read-only, read, and closed before the next Project's is opened. The read
    /// never creates or migrates a Journal, and no value in the result comes from two Projects. A Journal
    /// that cannot be read makes its own Project's `journalFailure` and leaves its siblings unchanged.
    ///
    /// An unexpired Act Lease with no matching closing event supplies the running Act and status.
    /// Closing lifecycle evidence or expiry suppresses stale job status; otherwise `actJobs` is the
    /// fallback when no lease exists or the Journal cannot be read.
    public static func read(
        configuration: Configuration, configurationDirectory: URL, actJobs: ActJobs, asOf: Date
    ) -> LandingSnapshot {
        LandingSnapshot(
            projects: configuration.projects.map {
                ProjectSnapshot.read(
                    $0, configurationDirectory: configurationDirectory, actJobs: actJobs, asOf: asOf
                )
            },
            asOf: asOf
        )
    }
}

extension ProjectSnapshot {
    /// One Project's snapshot: its name and Repos from its configuration, its Pulse from its Journal.
    static func read(
        _ project: ProjectConfiguration, configurationDirectory: URL, actJobs: ActJobs, asOf: Date
    ) -> ProjectSnapshot {
        var snapshot = ProjectSnapshot(
            id: project.id,
            name: project.name,
            repos: project.repos.map(\.name),
            pulse: .empty
        )
        let status: ProjectStatus = actJobs.isAlive(projectID: project.id) ? .working : .idle
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project.id)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project.id)
            snapshot.pulse = try PulseSnapshot.read(from: journal, status: status, asOf: asOf)
        } catch JournalError.missing {
            // No Act of this Project has finished opening a Journal yet. The empty Pulse is true, but
            // for the status: a first-ever Act may be running before its Journal exists, so the status
            // still reflects the job. Nothing needs the Operator, and there is no Feature and no Night.
            snapshot.pulse.now.status = status
        } catch {
            // The status still falls back to the Project's jobs when its Journal cannot be read (#233).
            snapshot.journalFailure = "\(error)"
            snapshot.pulse.now.status = status
        }
        return snapshot
    }
}

extension PulseSnapshot {
    /// The Pulse of a Project whose Journal holds nothing yet.
    static let empty = PulseSnapshot(
        needsYou: NeedsYou(cards: []),
        now: Now(status: .idle, nextAct: nil, attempts: []),
        feature: nil,
        night: nil,
        health: nil
    )
}
