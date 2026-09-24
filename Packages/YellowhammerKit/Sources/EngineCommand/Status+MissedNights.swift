import Config
import Domain
import Foundation
import Journal

extension Status {
    /// Every missed Night among the last `examinedNights`, diagnosed. `journal.recordedNights` nil
    /// means no Journal (or it could not be read) — `MissedNightDiagnosis.missedWindows` treats that
    /// as "examine only the most recent ended window, and it is missed".
    func missedNights(
        project: ProjectConfiguration, staggerIndex: Int, journal: JournalStatus,
        jobs: [(act: Act, state: LaunchAgentJobState)],
        sleepHistory: SleepHistory?
    ) -> [MissedNight] {
        let windows = MissedNightDiagnosis.missedWindows(
            schedule: project.schedule, recordedNights: journal.recordedNights, now: now, calendar: calendar,
            examinedNights: examinedNights
        )
        guard !windows.isEmpty else { return [] }

        // A `[schedule]` this Project's stagger offset cannot be scheduled from (Schedule.FiringGridError)
        // leaves no known firing grid; every missed window falls back to just its own `night_start`.
        let firingsOfDay = try? project.schedule.firings(staggerIndex: staggerIndex)
        let logModifications = logModifications(projectID: project.id)
        let evidence = MissedNightDiagnosis.PreOpenEvidence(
            journalFailures: journal.journalFailures, logModifications: logModifications
        )

        return windows.map { window in
            let firings = Self.firingInstants(window: window, firingsOfDay: firingsOfDay, calendar: calendar)
            let cause = MissedNightDiagnosis.diagnose(
                window: window, firings: firings, jobs: jobs, preOpenEvidence: evidence, sleepHistory: sleepHistory
            )
            return MissedNight(window: window, cause: cause)
        }
    }

    private static func firingInstants(
        window: NightWindow, firingsOfDay: Schedule.ScheduledFirings?, calendar: Calendar
    ) -> [Date] {
        guard let firingsOfDay else { return [window.start] }
        let timesOfDay = firingsOfDay.author + firingsOfDay.build + firingsOfDay.land
        return MissedNightDiagnosis.firingInstants(window: window, firings: timesOfDay, calendar: calendar)
    }

    /// Each Act's LaunchAgent log file that exists, with its modification date and last non-empty
    /// line — evidence a pre-initialization crash can be read from. A log that does not exist yet
    /// (the Act has never fired) contributes nothing.
    private func logModifications(projectID: ProjectID) -> [MissedNightDiagnosis.LogModification] {
        Act.allCases.compactMap { act in
            let path = Self.logPath(homeDirectory: homeDirectory, projectID: projectID, act: act)
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: path.path(percentEncoded: false)),
                let modifiedAt = attributes[.modificationDate] as? Date
            else { return nil }
            return MissedNightDiagnosis.LogModification(
                act: act, url: path, modifiedAt: modifiedAt, lastLine: Self.lastNonEmptyLine(of: path)
            )
        }
    }

    /// `~/Library/Logs/Yellowhammer/<project>.<act>.log` (matches `ScheduledJob.logPath(homeDirectory:)`).
    private static func logPath(homeDirectory: URL, projectID: ProjectID, act: Act) -> URL {
        homeDirectory.appending(
            components: "Library", "Logs", "Yellowhammer", "\(projectID.rawValue).\(act.rawValue).log",
            directoryHint: .notDirectory
        )
    }

    /// The log's last non-empty line, reading at most its final 64 KiB — `launchd` appends to this
    /// file forever, so only the tail is ever relevant evidence.
    private static func lastNonEmptyLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let tailLimit: UInt64 = 64 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > tailLimit ? size - tailLimit : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init)
    }
}
