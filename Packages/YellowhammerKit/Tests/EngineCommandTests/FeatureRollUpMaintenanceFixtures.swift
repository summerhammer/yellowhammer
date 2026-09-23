import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// Fixtures for FeatureRollUpMaintenanceTests.swift (roadmap P12.3): a Feature Roll-up world — an
// Outbox and an open Night bound to a held Act Lease — plus direct row inserts for Cards, Refusals and
// Authoring Halts, split out to keep the test file under the file/type length limits.

struct RollUpWorld {
    let board: FakeWritingBoard
    let outbox: Outbox
    let runID: RunID
    let night: NightRecord
}

/// A run holding the Project's Act-scoped Lease, with an Outbox and an open Night bound to it — a
/// Feature Issue write needs no Card Lease.
func makeRollUpWorld(_ journal: JournalStore) throws -> RollUpWorld {
    let board = FakeWritingBoard()
    let runID = RunID()
    let ob = try outbox(journal, board: board, runID: runID)
    let opening = try journal.openNight(
        nightStart: NightStart(rawValue: "2026-09-24")!, mode: .rehearsal, act: .build, runID: runID
    )
    return RollUpWorld(board: board, outbox: ob, runID: runID, night: opening.night)
}

/// One member Card of a Roll-up fixture, inserted directly with full control over every field the
/// Roll-up reads (state, Waiting Reason, Block Reason) that the shared `insertMergeCard`/`insertGateCard`
/// fixtures do not expose.
struct RollUpCardDraft {
    let issueID: String
    let repository: String
    let order: Int
    let state: CardState
    var waitingReason: WaitingReason?
    var blockReason: String?

    init(
        issueID: String, repository: String, order: Int, state: CardState, waitingReason: WaitingReason? = nil,
        blockReason: String? = nil
    ) {
        self.issueID = issueID
        self.repository = repository
        self.order = order
        self.state = state
        self.waitingReason = waitingReason
        self.blockReason = blockReason
    }
}

@discardableResult
func insertRollUpCard(_ journal: JournalStore, cycleID: Int64, _ draft: RollUpCardDraft) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, waiting_reason, block_reason,
                budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, draft.issueID, draft.repository, "card", draft.order, draft.state.rawValue,
                draft.waitingReason?.rawValue, draft.blockReason, 0, JournalStore.timestamp(outboxEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

func setCardState(_ journal: JournalStore, cardID: Int64, state: CardState) throws {
    try journal.write { db in
        try db.execute(sql: "UPDATE card SET state = ? WHERE id = ?", arguments: [state.rawValue, cardID])
    }
}

/// Records and banks one answer reply against `cardID`, reusing an already-held Act Lease and open
/// Night — `FeatureMemberMarkersTests.bankAReply`'s pattern, minus claiming its own lease, since a
/// ``RollUpWorld``'s Outbox already holds one for the whole test.
func bankRollUpReply(_ journal: JournalStore, cardID: Int64, issueID: String, nightID: Int64, runID: RunID) throws {
    let draft = CardReplyDraft(
        cardID: cardID, issueID: issueID, questionID: nil, commentID: "comment-\(cardID)",
        body: "the answer", authorName: "Max", disposition: .answer, commentedAt: outboxEpoch
    )
    let reply = try journal.recordCardReply(draft, nightID: nightID, act: .build, runID: runID, now: outboxEpoch)
    _ = try journal.bankCardReply(id: reply.id, stamps: [], nightID: nightID, runID: runID, now: outboxEpoch)
}

func insertRefusalRow(
    _ journal: JournalStore, featureName: String, issueID: String, state: RefusalState, openedNightID: Int64
) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO refusal (
                feature_name, issue_id, state, content, opened_night_id, unanswered_nights,
                consecutive_refusals, created_at
            ) VALUES (?, ?, ?, ?, ?, 0, 1, ?)
            """,
            arguments: [
                featureName, issueID, state.rawValue, "thin spec", openedNightID, JournalStore.timestamp(outboxEpoch)
            ]
        )
    }
}

func updateRefusalState(_ journal: JournalStore, issueID: String, state: RefusalState) throws {
    try journal.write { db in
        try db.execute(
            sql: "UPDATE refusal SET state = ? WHERE issue_id = ?", arguments: [state.rawValue, issueID]
        )
    }
}

func insertAuthoringHaltRow(
    _ journal: JournalStore, featureName: String, issueID: String, state: AuthoringHaltState, openedNightID: Int64
) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO authoring_halt (
                feature_name, issue_id, state, cause_kind, content, opened_night_id, unanswered_nights,
                created_at
            ) VALUES (?, ?, ?, ?, ?, ?, 0, ?)
            """,
            arguments: [
                featureName, issueID, state.rawValue, "repository", "halted", openedNightID,
                JournalStore.timestamp(outboxEpoch)
            ]
        )
    }
}

func updateAuthoringHaltState(_ journal: JournalStore, issueID: String, state: AuthoringHaltState) throws {
    try journal.write { db in
        try db.execute(
            sql: "UPDATE authoring_halt SET state = ? WHERE issue_id = ?", arguments: [state.rawValue, issueID]
        )
    }
}
