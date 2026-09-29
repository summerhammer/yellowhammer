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
    public static func read(configuration: Configuration, configurationDirectory: URL, asOf: Date) -> LandingSnapshot {
        LandingSnapshot(
            projects: configuration.projects.map {
                ProjectSnapshot.read($0, configurationDirectory: configurationDirectory, asOf: asOf)
            },
            asOf: asOf
        )
    }
}

extension ProjectSnapshot {
    /// One Project's snapshot: its name and Repos from its configuration, its Pulse from its Journal.
    static func read(_ project: ProjectConfiguration, configurationDirectory: URL, asOf: Date) -> ProjectSnapshot {
        var snapshot = ProjectSnapshot(
            id: project.id,
            name: project.name,
            repos: project.repos.map(\.name),
            pulse: .empty
        )
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: project.id)
        do {
            let journal = try JournalStore.openReadOnly(at: fileURL, projectID: project.id)
            snapshot.pulse = try PulseSnapshot.read(from: journal, asOf: asOf)
        } catch JournalError.missing {
            // No Act of this Project has run yet. The empty Pulse is true: the Project is idle, nothing
            // needs the Operator, and it has had no Feature and no Night.
        } catch {
            snapshot.journalFailure = "\(error)"
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
