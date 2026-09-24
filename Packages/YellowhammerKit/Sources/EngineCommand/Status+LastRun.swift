import Config
import Domain
import Foundation
import Journal

extension Status {
    /// Everything a Project's Journal tells `yh status`: the last run and last Night, the recorded
    /// Nights (nil when there is no Journal or it could not be read), and pre-Night `ActIncomplete`
    /// events (evidence for a pre-initialization crash).
    struct JournalStatus {
        let lastRun: LastRunStatus
        let lastNight: NightRecord?
        let recordedNights: [NightStart]?
        let journalFailures: [JournalEventRecord]
    }

    /// Opens this Project's Journal read-only — never creates or migrates it — and reads everything
    /// `yh status` needs from it. A missing Journal or a read failure is reported, never thrown.
    func journalStatus(projectID: ProjectID) -> JournalStatus {
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: configurationDirectory, id: projectID)
        let journal: JournalStore
        do {
            journal = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
        } catch {
            let lastRun: LastRunStatus = Self.isMissing(error) ? .noJournal : .journalError("\(error)")
            return JournalStatus(lastRun: lastRun, lastNight: nil, recordedNights: nil, journalFailures: [])
        }

        do {
            let (status, night) = try lastRunStatus(journal: journal)
            let recordedNights = try journal.nights().map(\.nightStart)
            let journalFailures = try journal.events(ofType: .actIncomplete)
            return JournalStatus(
                lastRun: status, lastNight: night, recordedNights: recordedNights, journalFailures: journalFailures
            )
        } catch {
            return JournalStatus(
                lastRun: .journalError("\(error)"), lastNight: nil, recordedNights: nil, journalFailures: []
            )
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        guard let journalError = error as? JournalError, case .missing = journalError else { return false }
        return true
    }

    /// The latest event carrying a run id: that run's Act, first event time, and how it ended.
    private func lastRunStatus(journal: JournalStore) throws -> (status: LastRunStatus, lastNight: NightRecord?) {
        let lastNight = try journal.nights().last
        let events = try journal.events()
        guard
            let latestEvent = events.last(where: { $0.runID != nil }),
            let runID = latestEvent.runID, let act = latestEvent.act
        else {
            return (.noRunRecorded, lastNight)
        }

        let runEvents = events.filter { $0.runID == runID }
        let firstEventAt = runEvents.first?.occurredAt ?? latestEvent.occurredAt
        let ending = try Self.ending(for: runEvents, runID: runID, journal: journal, now: now)
        return (.run(act: act, runID: runID, firstEventAt: firstEventAt, ending: ending), lastNight)
    }

    /// The run's own terminal event, or — with none recorded — whether the Act-scoped Lease still
    /// belongs to it right now.
    private static func ending(
        for runEvents: [JournalEventRecord], runID: RunID, journal: JournalStore, now: Date
    ) throws -> LastRunEnding {
        for record in runEvents {
            switch record.event {
            case .actEnded: return .ended
            case .actIdle(let reason): return .idle(reason)
            case .actIncomplete(let reason): return .incomplete(reason: reason)
            case .actStoodDown: return .stoodDown
            default: continue
            }
        }
        let lease = try journal.currentActLease()
        guard let lease, lease.runID == runID, lease.isHeld(at: now) else {
            return .noEndingRecorded
        }
        return .runningNow
    }
}
