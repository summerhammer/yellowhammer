import Domain
import Foundation
import GRDB

// The Journal side of repairing an existing halted Feature (roadmap P22.5; spec: feature-authoring/
// select-the-next-feature, `#halted-authoring-repair`). A halt is a durable checkpoint on one known Feature,
// not a new intake lane: this file holds the checkpoint, the Feature Card's last observed workflow state (the
// condition every halt-related Feature Issue state write is decided against) and the Operator's Todo request.

/// What the Journal keeps beside an ``AuthoringHaltRecord`` so the same Feature can be resumed.
public struct AuthoringHaltCheckpoint: Equatable, Sendable {
    public let haltID: Int64
    /// The Linear workspace of the Project's Board Connection when the halt was recorded.
    public let boardConnection: String
    /// A local identity for the authoring transaction the halt belongs to, stable across restarts and
    /// recorded before the Feature Card exists on the board.
    public let transactionID: String
    /// The exact failing references: ``AuthoringHaltCause/detail``.
    public let causeDetail: String?
    /// The accepted selection, when the halt arose after the selector chose one.
    public let selection: SelectedFeature?
    /// The Feature Card's last observed workflow state: its id, its category and the revision (`updatedAt`) it
    /// was observed at. Nil until observed.
    public let observedStateID: String?
    public let observedCategory: BoardWorkflowStateCategory?
    public let observedAt: Date?
    /// Counts the Operator's moves into Todo. Moves once per move, never per observation.
    public let repairSeq: Int
    /// Whether the latest move into Todo still asks for validation.
    public let repairPending: Bool
    /// The request a validation last handled; a request is validated once.
    public let repairHandledSeq: Int

    /// The Operator's request awaiting a validation: pending and not yet handled.
    public var hasUnhandledRepairRequest: Bool { repairPending && repairHandledSeq < repairSeq }
}

extension JournalStore {
    /// The checkpoint of `haltID`; nil for a halt recorded without one.
    public func authoringHaltCheckpoint(haltID: Int64) throws -> AuthoringHaltCheckpoint? {
        try read { db in
            try Row.fetchOne(
                db, sql: "SELECT * FROM authoring_halt_checkpoint WHERE halt_id = ?", arguments: [haltID]
            ).map { try Self.haltCheckpoint(from: $0) }
        }
    }

    /// Every `open` or `expired` halt, oldest first — the ones a repair can still be asked of.
    public func liveAuthoringHalts() throws -> [AuthoringHaltRecord] {
        try openAuthoringHalts() + expiredAuthoringHalts()
    }

    /// Records the Feature Card's workflow state as the board holds it at `revision`. Never moves backwards:
    /// an observation older than the one held is ignored.
    ///
    /// `authoritative` is a board read: it replaces the held observation whatever its revision, since a read is
    /// what the board holds. Without it (the state Yellowhammer's own write is about to leave the card in) an
    /// older revision never overwrites a newer one.
    public func recordAuthoringHaltObservation(
        haltID: Int64, stateID: String, category: BoardWorkflowStateCategory?, revision: Date,
        authoritative: Bool = false
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE authoring_halt_checkpoint
                SET observed_state_id = ?, observed_category = ?, observed_at = ?
                WHERE halt_id = ? AND (? OR observed_at IS NULL OR observed_at <= ?)
                """,
                arguments: [
                    stateID, category?.rawValue, Self.timestamp(revision), haltID,
                    authoritative, Self.timestamp(revision)
                ]
            )
        }
    }

    /// Asks for a validation of `feature`'s repair: the Operator moved its Feature Card to Todo. A request
    /// already pending is the same request — a repeated observation changes nothing — and `isNew` is false.
    @discardableResult
    public func requestAuthoringRepair(
        haltID: Int64, feature: FeatureName, nightID: Int64, act: Act? = nil, runID: RunID? = nil,
        now: Date = Date()
    ) throws -> (seq: Int, isNew: Bool) {
        try write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT repair_seq, repair_pending FROM authoring_halt_checkpoint WHERE halt_id = ?",
                arguments: [haltID]
            ) else { throw JournalError.authoringHaltUnreadable(id: haltID) }
            let seq: Int = row["repair_seq"]
            let pending: Int = row["repair_pending"]
            if pending != 0 { return (seq, false) }
            try db.execute(
                sql: "UPDATE authoring_halt_checkpoint SET repair_seq = ?, repair_pending = 1 WHERE halt_id = ?",
                arguments: [seq + 1, haltID]
            )
            _ = try Self.insertEvent(
                db, .authoringHaltRepair(feature: feature.rawValue, step: "requested", detail: nil),
                stamp: EventStamp(act: act, runID: runID, nightID: nightID, now: Self.stored(now))
            )
            return (seq + 1, true)
        }
    }

    /// The Operator moved the Feature Card out of Todo again: the request is withdrawn.
    public func withdrawAuthoringRepairRequest(haltID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE authoring_halt_checkpoint SET repair_pending = 0 WHERE halt_id = ?",
                arguments: [haltID]
            )
        }
    }

    /// A validation handled request `seq`; it is not validated again.
    public func markAuthoringRepairHandled(haltID: Int64, seq: Int) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE authoring_halt_checkpoint SET repair_handled_seq = ?
                WHERE halt_id = ? AND repair_handled_seq < ?
                """,
                arguments: [seq, haltID, seq]
            )
        }
    }

    /// Appends one repair step to the Journal (see ``JournalEvent/authoringHaltRepair(feature:step:detail:)``).
    public func recordAuthoringRepairStep(
        feature: FeatureName, step: String, detail: String? = nil, nightID: Int64, act: Act? = nil,
        runID: RunID? = nil
    ) throws {
        try append(
            .authoringHaltRepair(feature: feature.rawValue, step: step, detail: detail),
            act: act, runID: runID, nightID: nightID
        )
    }

    // MARK: - Checkpoint rows

    static func insertHaltCheckpoint(
        _ db: Database, haltID: Int64, connection: String, detail: String?, selection: SelectedFeature?
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO authoring_halt_checkpoint (halt_id, board_connection, transaction_id, cause_detail, selection)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [haltID, connection, UUID().uuidString, detail, try Self.encodeSelection(selection)]
        )
    }

    /// A repeat halt on an `open` row moves the failing references and, when it carries one, the selection;
    /// a halt recorded before checkpoints existed gets its row here.
    static func refreshHaltCheckpoint(
        _ db: Database, haltID: Int64, detail: String?, selection: SelectedFeature?
    ) throws {
        if try Int.fetchOne(
            db, sql: "SELECT 1 FROM authoring_halt_checkpoint WHERE halt_id = ?", arguments: [haltID]
        ) == nil {
            return
        }
        try db.execute(
            sql: "UPDATE authoring_halt_checkpoint SET cause_detail = ? WHERE halt_id = ?",
            arguments: [detail, haltID]
        )
        if let selection {
            try db.execute(
                sql: "UPDATE authoring_halt_checkpoint SET selection = ? WHERE halt_id = ?",
                arguments: [try Self.encodeSelection(selection), haltID]
            )
        }
    }

    private static func haltCheckpoint(from row: Row) throws -> AuthoringHaltCheckpoint {
        let haltID: Int64 = row["halt_id"]
        let unreadable = { JournalError.authoringHaltUnreadable(id: haltID) }
        var observedAt: Date?
        if let text: String = row["observed_at"] {
            observedAt = try Self.date(text, onError: unreadable)
        }
        let category: String? = row["observed_category"]
        let selectionText: String? = row["selection"]
        let pending: Int = row["repair_pending"]
        return AuthoringHaltCheckpoint(
            haltID: haltID,
            boardConnection: row["board_connection"],
            transactionID: row["transaction_id"],
            causeDetail: row["cause_detail"],
            selection: try selectionText.map { try Self.decodeSelection($0, onError: unreadable) },
            observedStateID: row["observed_state_id"],
            observedCategory: category.flatMap(BoardWorkflowStateCategory.init(rawValue:)),
            observedAt: observedAt,
            repairSeq: row["repair_seq"],
            repairPending: pending != 0,
            repairHandledSeq: row["repair_handled_seq"]
        )
    }

    /// The selection as stored: a plain value, so a later build reads what an earlier one wrote.
    private struct StoredSelection: Codable {
        var name: String
        var reasoning: String
        var precededBy: String?
        var followedBy: String?
        var seam: String?
        var repositories: [String]
        var adoptedCardIssueIDs: [String]
    }

    private static func encodeSelection(_ selection: SelectedFeature?) throws -> String? {
        guard let selection else { return nil }
        let stored = StoredSelection(
            name: selection.name.rawValue, reasoning: selection.reasoning,
            precededBy: selection.sequence?.precededBy, followedBy: selection.sequence?.followedBy,
            seam: selection.sequence?.seam, repositories: selection.repositories,
            adoptedCardIssueIDs: selection.adoptedCardIssueIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(data: try encoder.encode(stored), encoding: .utf8)
    }

    private static func decodeSelection(_ text: String, onError: () -> Error) throws -> SelectedFeature {
        guard let stored = try? JSONDecoder().decode(StoredSelection.self, from: Data(text.utf8)),
              let name = FeatureName(rawValue: stored.name) else { throw onError() }
        var sequence: FeatureSequence?
        if let before = stored.precededBy, let after = stored.followedBy, let seam = stored.seam {
            sequence = FeatureSequence(precededBy: before, followedBy: after, seam: seam)
        }
        return SelectedFeature(
            name: name, reasoning: stored.reasoning, sequence: sequence, repositories: stored.repositories,
            adoptedCardIssueIDs: stored.adoptedCardIssueIDs
        )
    }
}
