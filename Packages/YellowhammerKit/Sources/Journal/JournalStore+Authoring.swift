import Domain
import Foundation
import GRDB

// The Journal side of the authoring transaction (roadmap P9.4; spec: feature-authoring/
// author-the-cycle-and-card-dag): the reads that key and resume it, and the one write that turns an
// applied board into Feature, Cycle and Card rows.

/// One newly authored Card's Journal row, once the board has applied its create.
public struct AuthoredCardRow: Equatable, Sendable {
    public let issueID: String
    public let repository: String
    public let kind: String
    public let order: Int

    public init(issueID: String, repository: String, kind: String, order: Int) {
        self.issueID = issueID
        self.repository = repository
        self.kind = kind
        self.order = order
    }
}

/// What the board now holds for an authoring plan: the Feature Issue's id and every newly created Card.
public struct AuthoredFeature: Equatable, Sendable {
    public let plan: FeatureAuthoringAcceptedPayload
    public let featureIssueID: String
    public let cards: [AuthoredCardRow]

    public init(plan: FeatureAuthoringAcceptedPayload, featureIssueID: String, cards: [AuthoredCardRow]) {
        self.plan = plan
        self.featureIssueID = featureIssueID
        self.cards = cards
    }
}

extension JournalStore {
    /// How many authoring transactions for this Feature name were rolled back — the `<n>` that keeps a
    /// retry's keys distinct from the failed entries an earlier transaction left in the Outbox.
    public func failedAuthoringTransactionCount(feature name: String) throws -> Int {
        try events(ofType: .featureAuthoringFailed).filter {
            if case .featureAuthoringFailed(let failed, _, _) = $0.event { return failed == name }
            return false
        }.count
    }

    /// The latest recorded authoring plan with no `featureAuthored` / `featureAuthoringFailed` after it
    /// for the same group key — an authoring transaction a killed or deferred Act left unfinished.
    public func unfinishedAuthoringPlan() throws -> FeatureAuthoringAcceptedPayload? {
        var unfinished: FeatureAuthoringAcceptedPayload?
        for record in try events() {
            switch record.event {
            case .featureAuthoringAccepted(let plan):
                unfinished = plan
            case .featureAuthored(let payload) where payload.groupKey == unfinished?.groupKey:
                unfinished = nil
            case .featureAuthoringFailed(_, let groupKey, _) where groupKey == unfinished?.groupKey:
                unfinished = nil
            default:
                continue
            }
        }
        return unfinished
    }

    /// The issue id of the Feature a Card currently belongs to (card → cycle → feature), the parent an
    /// adoption's rollback restores. Nil when the Card has no row.
    public func featureIssueID(ofCardIssueID issueID: String) throws -> String? {
        try read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT feature.issue_id FROM card
                JOIN cycle ON cycle.id = card.cycle_id
                JOIN feature ON feature.id = cycle.feature_id
                WHERE card.issue_id = ?
                """,
                arguments: [issueID]
            )
        }
    }

    /// Writes the Feature, its Cycle and its Cards in ONE transaction and appends `featureAuthored`.
    /// Adopted Cards move into the new Cycle: `cycle_id` and `authored_order` change and nothing else —
    /// counters, Block Reason, state and budget epoch are untouched, so an adopted Card gets no new
    /// budgets. Idempotent: a Feature row with this issue id already there writes nothing and returns nil.
    /// Returns the new Cycle's id. `nightID` stamps the event; the Feature's own `selected_night_id` is the plan's.
    @discardableResult
    public func finaliseAuthoring(
        _ authored: AuthoredFeature,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> Int64? {
        let now = JournalStore.stored(now)
        let (plan, featureIssueID, cards) = (authored.plan, authored.featureIssueID, authored.cards)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            let existing = try Int.fetchOne(
                db, sql: "SELECT 1 FROM feature WHERE issue_id = ?", arguments: [featureIssueID]
            )
            guard existing == nil else { return nil }

            let timestamp = JournalStore.timestamp(now)
            try db.execute(
                sql: "INSERT INTO feature (issue_id, selected_night_id, state, created_at) VALUES (?, ?, ?, ?)",
                arguments: [featureIssueID, plan.nightID, "selected", timestamp]
            )
            let featureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
            )
            let cycleID = db.lastInsertedRowID

            for card in cards {
                try db.execute(
                    sql: """
                    INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        cycleID, card.issueID, card.repository, card.kind, card.order, CardState.todo.rawValue,
                        timestamp
                    ]
                )
            }
            for adoption in plan.adoptions {
                try db.execute(
                    sql: "UPDATE card SET cycle_id = ?, authored_order = ? WHERE issue_id = ?",
                    arguments: [cycleID, adoption.order, adoption.cardIssueID]
                )
                guard db.changesCount == 1 else {
                    throw JournalError.adoptedCardUnknown(issueID: adoption.cardIssueID)
                }
            }

            let payload = FeatureAuthoredPayload(
                name: plan.name, groupKey: plan.groupKey, featureIssueID: featureIssueID, cycleID: cycleID,
                cardCount: cards.count, adoptedCount: plan.adoptions.count
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(db, .featureAuthored(payload), stamp: stamp)
            return cycleID
        }
    }
}
