import Domain
import Foundation
import GRDB

// The Journal side of a halted Feature's draft children (roadmap P22.6; spec: feature-authoring/
// select-the-next-feature, `#halted-authoring-repair`). When a halt arises after a breakdown was produced, the
// breakdown is kept in the halt's checkpoint FIRST; the breakdown's Work Cards are then posted as repairable
// draft children under the halted Feature Card, each through the Outbox, and each returned issue id is recorded
// here before any later write. A draft is not a Card: there is no `card` row, it belongs to no Cycle, and nothing
// dispatches it.

/// Where a draft child came from.
public enum AuthoringHaltDraftSource: String, Equatable, Sendable {
    /// Posted by Yellowhammer from the checkpointed breakdown.
    case authored
    /// A child the Operator created beneath the halted Feature Card, admitted by the Delta Read.
    case board
}

/// One draft child of a halted Feature Card.
public struct AuthoringHaltDraft: Equatable, Sendable {
    public let id: Int64
    public let haltID: Int64
    public let source: AuthoringHaltDraftSource
    /// The child's position among the drafts: authored ones in breakdown order, then admitted ones in the order
    /// the Delta Read admitted them.
    public let position: Int
    /// The Outbox key the child's create was accepted under; nil for an admitted child.
    public let outboxKey: String?
    /// The child's board issue id; nil until its create is applied.
    public let issueID: String?
    public let repository: String?
    public let kind: String?
    public let title: String?
    /// The revision (`updatedAt`) the child was last observed at.
    public let observedAt: Date?
    /// The exact revision an accepted result was validated against.
    public let admittedRevision: Date?
}

/// One draft a halt's checkpointed breakdown asks to be posted.
public struct AuthoringHaltDraftSeed: Equatable, Sendable {
    public let outboxKey: String
    public let position: Int
    public let repository: String
    public let kind: String
    public let title: String

    public init(outboxKey: String, position: Int, repository: String, kind: String, title: String) {
        self.outboxKey = outboxKey
        self.position = position
        self.repository = repository
        self.kind = kind
        self.title = title
    }
}

extension JournalStore {
    /// Every draft child of `haltID`, in position order.
    public func authoringHaltDrafts(haltID: Int64) throws -> [AuthoringHaltDraft] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM authoring_halt_draft WHERE halt_id = ? ORDER BY position, id",
                arguments: [haltID]
            ).map { try Self.haltDraft(from: $0) }
        }
    }

    /// Registers the drafts a checkpointed breakdown asks for. A key already registered is left as it is, so
    /// registering again after a crash changes nothing.
    public func registerAuthoringHaltDrafts(haltID: Int64, seeds: [AuthoringHaltDraftSeed]) throws {
        try write { db in
            for seed in seeds {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO authoring_halt_draft
                    (halt_id, source, position, outbox_key, repository, kind, title)
                    VALUES (?, 'authored', ?, ?, ?, ?, ?)
                    """,
                    arguments: [haltID, seed.position, seed.outboxKey, seed.repository, seed.kind, seed.title]
                )
            }
        }
    }

    /// Persists the issue id the board returned for the draft created under `outboxKey`.
    public func recordAuthoringHaltDraftIssue(haltID: Int64, outboxKey: String, issueID: String) throws {
        try write { db in
            // The Delta Read may have admitted the child before its id was recorded here: it is one draft.
            try db.execute(
                sql: "DELETE FROM authoring_halt_draft WHERE halt_id = ? AND issue_id = ? AND outbox_key IS NULL",
                arguments: [haltID, issueID]
            )
            try db.execute(
                sql: """
                UPDATE authoring_halt_draft SET issue_id = ?
                WHERE halt_id = ? AND outbox_key = ? AND issue_id IS NULL
                """,
                arguments: [issueID, haltID, outboxKey]
            )
        }
    }

    /// Admits `issueID` — a child currently nested beneath the halted Feature Card — into the halt's candidate
    /// snapshot, or refreshes the revision it was last observed at. It stays a draft.
    public func admitAuthoringHaltChild(
        haltID: Int64, issueID: String, title: String, revision: Date
    ) throws {
        try write { db in
            let stamp = Self.timestamp(revision)
            try db.execute(
                sql: """
                UPDATE authoring_halt_draft SET title = ?, observed_at = ?
                WHERE halt_id = ? AND issue_id = ? AND (observed_at IS NULL OR observed_at <= ?)
                """,
                arguments: [title, stamp, haltID, issueID, stamp]
            )
            if db.changesCount > 0 { return }
            if try Int.fetchOne(
                db, sql: "SELECT 1 FROM authoring_halt_draft WHERE halt_id = ? AND issue_id = ?",
                arguments: [haltID, issueID]
            ) != nil { return }
            let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM authoring_halt_draft WHERE halt_id = ?",
                arguments: [haltID]
            ) ?? 1
            try db.execute(
                sql: """
                INSERT INTO authoring_halt_draft (halt_id, source, position, issue_id, title, observed_at)
                VALUES (?, 'board', ?, ?, ?, ?)
                """,
                arguments: [haltID, next, issueID, title, stamp]
            )
        }
    }

    /// Records the exact revisions of the children an accepted result was validated against.
    public func recordAuthoringHaltAdmittedRevisions(haltID: Int64, revisions: [String: Date]) throws {
        try write { db in
            for (issueID, revision) in revisions {
                try db.execute(
                    sql: "UPDATE authoring_halt_draft SET admitted_revision = ? WHERE halt_id = ? AND issue_id = ?",
                    arguments: [Self.timestamp(revision), haltID, issueID]
                )
            }
        }
    }

    /// Keeps (or clears, with nil) the diagnostic of the latest repair that was not accepted.
    public func recordAuthoringRepairDiagnostic(haltID: Int64, diagnostic: String?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE authoring_halt_checkpoint SET repair_diagnostic = ? WHERE halt_id = ?",
                arguments: [diagnostic, haltID]
            )
        }
    }

    /// The live halt whose Feature Card is `parentIssueID`, on this Project's Board Connection: the one a child
    /// nested beneath that issue is admitted to. Nil for any other issue — an orphan, a free-standing Feature, a
    /// child of something else stays unknown.
    public func liveAuthoringHalt(featureIssueID parentIssueID: String) throws -> AuthoringHaltRecord? {
        try liveAuthoringHalts().first { halt in
            guard halt.issueID == parentIssueID,
                  let checkpoint = try? authoringHaltCheckpoint(haltID: halt.id) else { return false }
            return checkpoint.boardConnection == linearWorkspace.rawValue
        }
    }

    private static func haltDraft(from row: Row) throws -> AuthoringHaltDraft {
        let id: Int64 = row["id"]
        let unreadable = { JournalError.authoringHaltUnreadable(id: row["halt_id"]) }
        let observedText: String? = row["observed_at"]
        let admittedText: String? = row["admitted_revision"]
        let sourceText: String = row["source"]
        guard let source = AuthoringHaltDraftSource(rawValue: sourceText) else { throw unreadable() }
        return AuthoringHaltDraft(
            id: id, haltID: row["halt_id"], source: source, position: row["position"],
            outboxKey: row["outbox_key"], issueID: row["issue_id"], repository: row["repository"],
            kind: row["kind"], title: row["title"],
            observedAt: try observedText.map { try Self.date($0, onError: unreadable) },
            admittedRevision: try admittedText.map { try Self.date($0, onError: unreadable) }
        )
    }

    // MARK: - The checkpointed breakdown

    static func encodeBreakdown(_ breakdown: FeatureBreakdown?) throws -> String? {
        guard let breakdown else { return nil }
        let stored = StoredBreakdown(
            definitionOfDone: breakdown.definitionOfDone.map {
                StoredBreakdownClause(text: $0.text, citation: $0.citation.rawValue)
            },
            cards: breakdown.cards.map { card in
                StoredBreakdownCard(
                    repository: card.repository, kind: card.kind.description, title: card.title,
                    unitOfWork: card.unitOfWork, brief: card.brief,
                    definitionOfDone: card.definitionOfDone.map {
                        StoredBreakdownClause(text: $0.text, citation: $0.citation.rawValue)
                    },
                    contracts: card.contracts.map {
                        StoredBreakdownContract(
                            repository: $0.repository, paths: $0.paths, ranges: $0.ranges, symbol: $0.symbol
                        )
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(data: try encoder.encode(stored), encoding: .utf8)
    }

    static func decodeBreakdown(_ text: String, onError: () -> Error) throws -> FeatureBreakdown {
        guard let stored = try? JSONDecoder().decode(StoredBreakdown.self, from: Data(text.utf8)) else {
            throw onError()
        }
        let cards = try stored.cards.map { card -> CardDraft in
            guard let kind = Kind(card.kind) else { throw onError() }
            return CardDraft(
                repository: card.repository, kind: kind, title: card.title, unitOfWork: card.unitOfWork,
                brief: card.brief,
                definitionOfDone: card.definitionOfDone.map {
                    DefinitionOfDoneClauseDraft(text: $0.text, citation: SpecCitation($0.citation))
                },
                contracts: card.contracts.map {
                    ContractDraft(repository: $0.repository, paths: $0.paths, ranges: $0.ranges, symbol: $0.symbol)
                }
            )
        }
        return FeatureBreakdown(
            definitionOfDone: stored.definitionOfDone.map {
                DefinitionOfDoneClauseDraft(text: $0.text, citation: SpecCitation($0.citation))
            },
            cards: cards
        )
    }
}

// The breakdown as stored: plain values, so a later build reads what an earlier one wrote.

private struct StoredBreakdownClause: Codable {
    var text: String
    var citation: String
}

private struct StoredBreakdownContract: Codable {
    var repository: String
    var paths: [String]
    var ranges: [String: [LineRange]]
    var symbol: String?
}

private struct StoredBreakdownCard: Codable {
    var repository: String
    var kind: String
    var title: String
    var unitOfWork: String
    var brief: String
    var definitionOfDone: [StoredBreakdownClause]
    var contracts: [StoredBreakdownContract]
}

private struct StoredBreakdown: Codable {
    var definitionOfDone: [StoredBreakdownClause]
    var cards: [StoredBreakdownCard]
}
