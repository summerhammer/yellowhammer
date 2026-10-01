import Domain
import Foundation
import GRDB

// Banking a Card Reply (roadmap P11.3; spec: board-projection/read-board-changes-by-delta, OQ37): once
// the Feature that put a Card in Waiting on You has landed, lanes do not reopen and an answer is never
// dispatched — it is banked instead, into the `banked_reply` / `banked_reply_mainline` tables the schema carries
// for exactly this (``JournalMigrations/createBankedReplyTable(_:)``,
// ``JournalMigrations/createBankedReplyMainlineTable(_:)``), and carried forward for opportunistic
// Adoption by a successor Feature (roadmap P11.5). A reply is banked iff a `banked_reply` row exists
// with its `comment_id` — both columns are UNIQUE, so that is a one-to-one join, never ambiguous.

/// One Repo's mainline commit stamped onto a banked reply, at the moment it was banked. `commit` is nil
/// when the mainline could not be resolved at banking time — `banked_reply_mainline` records that as
/// the row's absence, never a guessed value, so a stamp read back from the Journal always has a
/// non-nil commit; `commit` stays optional here only so the Engine can represent "no stored row" the
/// same way it represents "not yet resolved" when it renders the acknowledgement.
public struct MainlineStamp: Equatable, Sendable {
    public let repository: String
    public let commit: String?

    public init(repository: String, commit: String?) {
        self.repository = repository
        self.commit = commit
    }
}

/// A banked ``CardReplyRecord``, the Night it was banked on, and the mainline stamps it was banked
/// with (resolved repositories only — an unresolved repository is simply absent), ordered by
/// repository.
public struct BankedCardReply: Equatable, Sendable {
    public let reply: CardReplyRecord
    public let nightID: Int64
    public let bankedAt: Date
    public let stamps: [MainlineStamp]
}

extension JournalStore {
    /// Banks `id` (an answer already recorded in `card_reply`): inserts one `banked_reply` row keyed by
    /// the reply's own `comment_id`, one `banked_reply_mainline` row per resolved stamp, and appends
    /// `.waitingOnYouReplyBanked` — all in one write transaction. Idempotent: a `banked_reply` row
    /// already keyed by this comment id is returned unchanged, with the stamps it was first banked
    /// with — `stamps` passed to a repeat call are simply ignored, and no second event is appended.
    /// Throws ``JournalError/cardReplyUnreadable(id:)`` for an unknown reply, or
    /// ``JournalError/cardReplyNotAnswer(id:)`` when its disposition is not `answer`.
    @discardableResult
    public func bankCardReply(
        id: Int64,
        stamps: [MainlineStamp],
        nightID: Int64,
        act: Act? = nil,
        runID: RunID? = nil,
        now: Date = Date()
    ) throws -> BankedCardReply {
        try write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card_reply WHERE id = ?", arguments: [id])
            else {
                throw JournalError.cardReplyUnreadable(id: id)
            }
            let reply = try Self.cardReplyRecord(from: row)
            guard reply.disposition == .answer else {
                throw JournalError.cardReplyNotAnswer(id: id)
            }

            if let existing = try Self.fetchBankedReply(db, commentID: reply.commentID, reply: reply) {
                return existing
            }

            let bankedAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                INSERT INTO banked_reply (card_id, night_id, comment_id, body, banked_at) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [reply.cardID, reply.nightID, reply.commentID, reply.body, JournalStore.timestamp(bankedAt)]
            )
            let bankedReplyID = db.lastInsertedRowID
            for stamp in stamps where stamp.commit != nil {
                try db.execute(
                    sql: """
                    INSERT INTO banked_reply_mainline (banked_reply_id, repository, mainline_commit) VALUES (?, ?, ?)
                    """,
                    arguments: [bankedReplyID, stamp.repository, stamp.commit]
                )
            }

            guard
                let issueID = try String.fetchOne(
                    db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [reply.cardID]
                )
            else {
                throw JournalError.cardUnknown(cardID: reply.cardID)
            }
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db,
                .waitingOnYouReplyBanked(cardID: reply.cardID, issueID: issueID, commentID: reply.commentID),
                stamp: stamp
            )

            let storedStamps = try Self.mainlineStamps(db, bankedReplyID: bankedReplyID)
            return BankedCardReply(reply: reply, nightID: reply.nightID, bankedAt: bankedAt, stamps: storedStamps)
        }
    }

    /// Every banked reply of `cardID`, in Journal order (`card_reply.id` ASC) — the order an adopting
    /// dispatch will carry them in (roadmap P11.5), and what the unanswered-nights clock (roadmap
    /// P11.4) reads to stop.
    public func bankedCardReplies(cardID: Int64) throws -> [BankedCardReply] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT card_reply.*, banked_reply.id AS banked_reply_id, banked_reply.night_id AS banked_night_id,
                banked_reply.banked_at AS banked_at
                FROM card_reply
                JOIN banked_reply ON banked_reply.comment_id = card_reply.comment_id
                WHERE card_reply.card_id = ?
                ORDER BY card_reply.id ASC
                """,
                arguments: [cardID]
            )
            return try rows.map { try Self.bankedCardReply(db, from: $0) }
        }
    }

    /// Every Card id in `cycleID` with at least one banked reply.
    public func cardIDsWithBankedReplies(cycleID: Int64) throws -> Set<Int64> {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT card_reply.card_id AS card_id FROM card_reply
                JOIN banked_reply ON banked_reply.comment_id = card_reply.comment_id
                JOIN card ON card.id = card_reply.card_id
                WHERE card.cycle_id = ?
                """,
                arguments: [cycleID]
            )
            return Set(rows.map { $0["card_id"] as Int64 })
        }
    }

    /// Whether any Card is in Waiting on You in a Cycle that has already landed — the author Act's own
    /// cheap check (roadmap P11.3) for whether it has anything to bank before spending a Delta Read.
    public func hasWaitingOnYouCardInLandedCycle() throws -> Bool {
        try read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM card
                JOIN cycle ON cycle.id = card.cycle_id
                WHERE card.state = ? AND cycle.landed_at IS NOT NULL
                """,
                arguments: [CardState.waitingOnYou.rawValue]
            ) ?? 0
            return count > 0
        }
    }

    /// Fetches the existing `banked_reply` row keyed by `commentID`, if any, with its stored stamps —
    /// the idempotent-replay path of ``bankCardReply(id:stamps:nightID:act:runID:now:)``.
    private static func fetchBankedReply(
        _ db: Database, commentID: String, reply: CardReplyRecord
    ) throws -> BankedCardReply? {
        guard
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM banked_reply WHERE comment_id = ?", arguments: [commentID]
            )
        else {
            return nil
        }
        let bankedAt = try Self.date(row["banked_at"] as String) { JournalError.cardReplyUnreadable(id: reply.id) }
        let bankedReplyID: Int64 = row["id"]
        let stamps = try Self.mainlineStamps(db, bankedReplyID: bankedReplyID)
        return BankedCardReply(reply: reply, nightID: row["night_id"], bankedAt: bankedAt, stamps: stamps)
    }

    private static func bankedCardReply(_ db: Database, from row: Row) throws -> BankedCardReply {
        let reply = try Self.cardReplyRecord(from: row)
        let bankedReplyID: Int64 = row["banked_reply_id"]
        let bankedAt = try Self.date(row["banked_at"] as String) { JournalError.cardReplyUnreadable(id: reply.id) }
        let stamps = try Self.mainlineStamps(db, bankedReplyID: bankedReplyID)
        return BankedCardReply(reply: reply, nightID: row["banked_night_id"], bankedAt: bankedAt, stamps: stamps)
    }

    private static func mainlineStamps(_ db: Database, bankedReplyID: Int64) throws -> [MainlineStamp] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT repository, mainline_commit FROM banked_reply_mainline
            WHERE banked_reply_id = ? ORDER BY repository ASC
            """,
            arguments: [bankedReplyID]
        )
        return rows.map { MainlineStamp(repository: $0["repository"], commit: $0["mainline_commit"]) }
    }
}
