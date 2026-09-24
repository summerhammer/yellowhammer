import Domain
import Foundation
import GRDB

/// One Night of this Project as the Journal records it: one run of the Shift for one Project, from
/// its first Act firing to its close. `projectID` is first-class on the row (OQ52), even though a
/// Journal holds one Project's Nights only, so the row names its Project without deriving it.
public struct NightRecord: Equatable, Sendable {
    public let id: Int64
    public let projectID: ProjectID
    public let nightStart: NightStart
    public let mode: NightMode
    public let state: NightState
    public let nightCardIssueID: String?
    public let openedAt: Date
    /// When the Night was closed in the Journal; `closeReason` says how. Nil while it is open.
    public let completedAt: Date?
    public let closeReason: NightCloseReason?
    /// The Night Summary's constant-time verdict line (OQ13); nil until something writes one.
    /// `idle` is the only value this phase writes — the author Act finding nothing selectable.
    public let verdict: NightVerdict?
    /// When this Night's morning was triaged (roadmap P10.8/P10.9; spec: morning-report/triage-the-
    /// morning): written at the Operator's settle (P10.9) or on observing a Partial
    /// Landing's merge closure (P10.8). The one field a closed Night may still change.
    public let triagedAt: Date?

    public var isOpen: Bool { state == .opened }
}

/// What an Act learns when it opens its Night.
public struct NightOpening: Equatable, Sendable {
    /// The Night this Act belongs to: recorded by this call, or found already recorded.
    public let night: NightRecord
    /// True when this call recorded the Night, i.e. this run is the first Act of the Night.
    public let isFirstAct: Bool
    /// Nights this Project left open with no completion, closed by this call as opened-and-died.
    public let openedAndDied: [NightRecord]
    /// The Nights the audit found missing, ascending; empty on a repeat open.
    public let absentNights: [NightStart]
}

extension JournalStore {
    /// Records the Night at its first Act, or hands a later Act the Night already recorded.
    ///
    /// One write transaction under the Act-scoped lease. A Night is identified by the date of its
    /// `night_start` (G-7), so a second Act of the same Night finds the row and writes nothing —
    /// closed or not: an Act firing after the Night was closed still belongs to that Night, and
    /// nothing reopens it. When no row exists, this run is the first Act of a new Night, and it first
    /// sweeps: every Night of this Project still `opened` is one that opened and died — nothing else
    /// could have left it open, since a Night that ended through the front door is closed — so each
    /// is closed as such and the observation is recorded as an event of the *new* Night.
    ///
    /// The resumption self-audit runs on the new-Night path: the first Act of a new Night finds the
    /// latest recorded Night of this Project (whatever its state); if it exists and is earlier than
    /// the new Night, each calendar date between them is a Night that should have opened and did not.
    /// Each absent Night is recorded as an event of the new Night. The audit reports and never acts on
    /// these Nights: `unanswered_nights_max` is spent only by Nights that ran. A sibling Project's
    /// Night is in a different Journal, so it is neither seen nor reported here.
    public func openNight(
        nightStart: NightStart,
        mode: NightMode,
        act: Act,
        runID: RunID,
        now: Date = Date()
    ) throws -> NightOpening {
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            if let existing = try Self.fetchNight(db, projectID: projectID, nightStart: nightStart) {
                return NightOpening(night: existing, isFirstAct: false, openedAndDied: [], absentNights: [])
            }
            let leftOpen = try Self.fetchOpenNights(db, projectID: projectID)
            var openedAndDied: [NightRecord] = []
            for night in leftOpen {
                openedAndDied.append(try Self.close(db, night: night, reason: .openedAndDied, now: now))
            }
            let absentNights = try Self.absentNights(db, projectID: projectID, before: nightStart)
            try db.execute(
                sql: """
                INSERT INTO night (project_id, night_start, mode, state, opened_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    projectID.rawValue, nightStart.rawValue, mode.rawValue,
                    NightState.opened.rawValue, JournalStore.timestamp(now)
                ]
            )
            let night = NightRecord(
                id: db.lastInsertedRowID, projectID: projectID, nightStart: nightStart, mode: mode,
                state: .opened, nightCardIssueID: nil, openedAt: now, completedAt: nil, closeReason: nil,
                verdict: nil, triagedAt: nil
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: night.id, now: now)
            _ = try Self.insertEvent(db, .nightOpened, stamp: stamp)
            for dead in openedAndDied {
                let event = JournalEvent.nightOpenedAndDied(nightID: dead.id, nightStart: dead.nightStart)
                _ = try Self.insertEvent(db, event, stamp: stamp)
            }
            for absentNightStart in absentNights {
                let event = JournalEvent.absentNightDetected(nightStart: absentNightStart)
                _ = try Self.insertEvent(db, event, stamp: stamp)
            }
            return NightOpening(
                night: night, isFirstAct: true, openedAndDied: openedAndDied, absentNights: absentNights
            )
        }
    }

    /// Closes an open Night with the reason it closed, recording it as an event of that Night. One
    /// write transaction under the Act-scoped lease. Closing a closed Night is refused: a Night
    /// closes once, and its reason is the one it closed with.
    @discardableResult
    public func closeNight(
        id: Int64,
        reason: NightCloseReason,
        act: Act,
        runID: RunID,
        now: Date = Date()
    ) throws -> NightRecord {
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let night = try Self.fetchNight(db, id: id) else {
                throw JournalError.nightUnknown(id: id)
            }
            guard night.isOpen else {
                throw JournalError.nightAlreadyClosed(id: id)
            }
            let closed = try Self.close(db, night: night, reason: reason, now: now)

            let stamp = EventStamp(act: act, runID: runID, nightID: id, now: now)
            _ = try Self.insertEvent(db, .nightClosed(reason: reason), stamp: stamp)
            return closed
        }
    }

    /// The one open Night of this Project, or nil. `openNight` closes every other open Night before
    /// it records a new one, so two is a Journal written by something other than the engine.
    public func currentNight() throws -> NightRecord? {
        try read { db in
            let open = try Self.fetchOpenNights(db, projectID: projectID)
            guard open.count <= 1 else {
                throw JournalError.multipleOpenNights
            }
            return open.first
        }
    }

    /// The Night with this id, open or closed.
    public func night(id: Int64) throws -> NightRecord? {
        try read { db in try Self.fetchNight(db, id: id) }
    }

    /// Records the Night Card's issue id, the first Act of the Night creating it before any work
    /// (DR7). One write transaction under the Act-scoped lease. A repeat of the same issue id is a
    /// no-op — the Outbox's replay after a crash resolves to the same create — and a different id
    /// throws ``JournalError/nightCardAlreadyRecorded(id:issueID:)``, because one Night gets one card.
    @discardableResult
    public func recordNightCard(
        id: Int64,
        issueID: String,
        act: Act,
        runID: RunID,
        now: Date = Date()
    ) throws -> NightRecord {
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let night = try Self.fetchNight(db, id: id) else {
                throw JournalError.nightUnknown(id: id)
            }
            if let existing = night.nightCardIssueID {
                guard existing == issueID else {
                    throw JournalError.nightCardAlreadyRecorded(id: id, issueID: existing)
                }
                return night
            }
            try db.execute(
                sql: "UPDATE night SET night_card_issue_id = ? WHERE id = ?",
                arguments: [issueID, id]
            )
            let updated = NightRecord(
                id: night.id,
                projectID: night.projectID,
                nightStart: night.nightStart,
                mode: night.mode,
                state: night.state,
                nightCardIssueID: issueID,
                openedAt: night.openedAt,
                completedAt: night.completedAt,
                closeReason: night.closeReason,
                verdict: night.verdict,
                triagedAt: night.triagedAt
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: id, now: now)
            _ = try Self.insertEvent(db, .nightCardOpened(issueID: issueID), stamp: stamp)
            return updated
        }
    }

    /// Records the author Act's finding nothing selectable to author (`AuthoringNoWorkAvailable`,
    /// OQ13): the one place the Night's idle verdict is written. Refuses a closed Night — the verdict
    /// belongs to the Night that is still open when authoring runs. One write transaction under the
    /// Act-scoped lease.
    @discardableResult
    public func recordAuthoringNoWorkAvailable(
        nightID: Int64,
        act: Act,
        runID: RunID,
        now: Date = Date()
    ) throws -> NightRecord {
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let night = try Self.fetchNight(db, id: nightID) else {
                throw JournalError.nightUnknown(id: nightID)
            }
            guard night.isOpen else {
                throw JournalError.nightAlreadyClosed(id: nightID)
            }
            try db.execute(
                sql: "UPDATE night SET verdict = ? WHERE id = ?",
                arguments: [NightVerdict.idle.rawValue, nightID]
            )
            let updated = NightRecord(
                id: night.id,
                projectID: night.projectID,
                nightStart: night.nightStart,
                mode: night.mode,
                state: night.state,
                nightCardIssueID: night.nightCardIssueID,
                openedAt: night.openedAt,
                completedAt: night.completedAt,
                closeReason: night.closeReason,
                verdict: .idle,
                triagedAt: night.triagedAt
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(db, .authoringNoWorkAvailable, stamp: stamp)
            return updated
        }
    }

    /// Every Night of this Project, oldest first.
    public func nights() throws -> [NightRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM night WHERE project_id = ? ORDER BY night_start ASC",
                arguments: [projectID.rawValue]
            )
            return try rows.map(Self.decodeNight)
        }
    }

    /// The absent Nights this Night's first Act found, in the order they were recorded. What the
    /// Night Summary reads to report the gap.
    public func absentNights(nightID: Int64) throws -> [NightStart] {
        try events(ofType: .absentNightDetected)
            .filter { $0.nightID == nightID }
            .compactMap { record in
                if case .absentNightDetected(let nightStart) = record.event { nightStart } else { nil }
            }
    }

    // MARK: - Rows

    /// `close`/`fetchOpenNights` widened from `private` for P13.5's `recordProjectRemoval`.
    static func close(
        _ db: Database,
        night: NightRecord,
        reason: NightCloseReason,
        now: Date
    ) throws -> NightRecord {
        if reason == .nightEnd {
            let counters = try Row.fetchOne(
                db,
                sql: "SELECT MAX(unanswered_nights) AS unanswered, MAX(failed_adoptions) AS adoptions FROM card"
            )
            let unanswered: Int = counters?["unanswered"] ?? 0
            let adoptions: Int = counters?["adoptions"] ?? 0
            let citations = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clause WHERE deleted = 0 AND citation_provenance = 'Author-supplied'"
            ) ?? 0
            try db.execute(
                sql: """
                UPDATE night SET closing_unanswered_max = ?, closing_failed_adoptions_max = ?,
                                 closing_author_supplied_citation_count = ? WHERE id = ?
                """, arguments: [unanswered, adoptions, citations, night.id]
            )
        }
        try db.execute(
            sql: "UPDATE night SET state = ?, close_reason = ?, completed_at = ? WHERE id = ?",
            arguments: [NightState.closed.rawValue, reason.rawValue, JournalStore.timestamp(now), night.id]
        )
        return NightRecord(
            id: night.id,
            projectID: night.projectID,
            nightStart: night.nightStart,
            mode: night.mode,
            state: .closed,
            nightCardIssueID: night.nightCardIssueID,
            openedAt: night.openedAt,
            completedAt: now,
            closeReason: reason,
            verdict: night.verdict,
            triagedAt: night.triagedAt
        )
    }

    private static func fetchNight(_ db: Database, id: Int64) throws -> NightRecord? {
        try Row.fetchOne(db, sql: "SELECT * FROM night WHERE id = ?", arguments: [id]).map(decodeNight)
    }

    private static func fetchNight(
        _ db: Database,
        projectID: ProjectID,
        nightStart: NightStart
    ) throws -> NightRecord? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM night WHERE project_id = ? AND night_start = ?",
            arguments: [projectID.rawValue, nightStart.rawValue]
        ).map(decodeNight)
    }

    static func fetchOpenNights(_ db: Database, projectID: ProjectID) throws -> [NightRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM night WHERE project_id = ? AND state = ? ORDER BY night_start ASC",
            arguments: [projectID.rawValue, NightState.opened.rawValue]
        )
        return try rows.map(decodeNight)
    }

    /// The Nights the schedule fired for between the last recorded Night and this one. The baseline
    /// is the latest Night whatever its state: one that opened and died still ran. With no baseline
    /// — the Project's first Night ever — nothing can be called absent.
    private static func absentNights(
        _ db: Database,
        projectID: ProjectID,
        before nightStart: NightStart
    ) throws -> [NightStart] {
        let latest = try Row.fetchOne(
            db,
            sql: "SELECT * FROM night WHERE project_id = ? ORDER BY night_start DESC LIMIT 1",
            arguments: [projectID.rawValue]
        ).map(decodeNight)
        guard let latest else { return [] }
        return NightStart.dates(strictlyBetween: latest.nightStart, and: nightStart)
    }

    private static func decodeNight(_ row: Row) throws -> NightRecord {
        let id: Int64 = row["id"]
        guard
            let projectID = ProjectID(rawValue: row["project_id"]),
            let nightStart = NightStart(rawValue: row["night_start"]),
            let mode = NightMode(rawValue: row["mode"]),
            let state = NightState(rawValue: row["state"])
        else {
            throw JournalError.nightUnreadable(id: id)
        }
        let closeReason = try (row["close_reason"] as String?).map { text in
            guard let reason = NightCloseReason(rawValue: text) else {
                throw JournalError.nightUnreadable(id: id)
            }
            return reason
        }
        let openedAt = try JournalStore.date(row["opened_at"] as String? ?? "") {
            JournalError.nightUnreadable(id: id)
        }
        let completedAt = try (row["completed_at"] as String?).map { text in
            try JournalStore.date(text) { JournalError.nightUnreadable(id: id) }
        }
        let verdict = try (row["verdict"] as String?).map { text in
            guard let verdict = NightVerdict(rawValue: text) else {
                throw JournalError.nightUnreadable(id: id)
            }
            return verdict
        }
        let triagedAt = try (row["triaged_at"] as String?).map { text in
            try JournalStore.date(text) { JournalError.nightUnreadable(id: id) }
        }
        return NightRecord(
            id: id,
            projectID: projectID,
            nightStart: nightStart,
            mode: mode,
            state: state,
            nightCardIssueID: row["night_card_issue_id"],
            openedAt: openedAt,
            completedAt: completedAt,
            closeReason: closeReason,
            verdict: verdict,
            triagedAt: triagedAt
        )
    }
}
