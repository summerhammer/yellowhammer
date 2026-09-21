import Domain
import Foundation
import GRDB

// Records a Cycle's Verification (roadmap P10.5; spec: verification/verify-a-feature-clause-by-clause),
// once per Cycle: first write wins, so a retried land Act reads the judgement it already made.

/// Who decided a clause's verdict.
public enum ClauseJudge: String, Equatable, Sendable {
    /// The verifier pass, dispatched through the Routing Table.
    case agent
    /// The engine, without asking an agent: a Card that did not complete, or a citation that no longer resolves.
    case engine
}

/// One clause of a Verification as judged, with the clause snapshotted as it stood.
public struct ClauseVerificationRecord: Equatable, Sendable {
    public let issueID: String
    public let cid: String
    public let level: String
    public let text: String
    public let locationID: String
    /// Straight from the `clause` table's `citation_provenance`: `machine-found` or `Author-supplied`.
    public let citationProvenance: String
    public let verdict: ClauseVerdict
    public let whatWasChecked: String
    public let interpretation: String
    public let judgedBy: ClauseJudge
    /// The clause row's `invalidated_cause`, when the board edited its text or citation after authoring.
    public let invalidatedCause: String?

    public init(
        issueID: String, cid: String, level: String, text: String, locationID: String,
        citationProvenance: String, verdict: ClauseVerdict, whatWasChecked: String, interpretation: String,
        judgedBy: ClauseJudge, invalidatedCause: String? = nil
    ) {
        self.issueID = issueID
        self.cid = cid
        self.level = level
        self.text = text
        self.locationID = locationID
        self.citationProvenance = citationProvenance
        self.verdict = verdict
        self.whatWasChecked = whatWasChecked
        self.interpretation = interpretation
        self.judgedBy = judgedBy
        self.invalidatedCause = invalidatedCause
    }
}

/// A Cycle's recorded Verification: its clauses in report order.
public struct FeatureVerificationRecord: Equatable, Sendable {
    public let id: Int64
    public let featureID: Int64
    public let cycleID: Int64
    /// The Route's description; nil when no verifier dispatch was needed.
    public let route: String?
    public let nightID: Int64
    public let runID: RunID
    public let verifiedAt: Date
    public let clauses: [ClauseVerificationRecord]
}

/// Everything a Cycle's Verification record needs, bundled so `recordFeatureVerification` stays under the
/// parameter-count limit.
public struct NewFeatureVerification: Sendable {
    public let featureID: Int64
    public let cycleID: Int64
    /// The Route's description; nil when no verifier dispatch was needed.
    public let route: String?
    public let nightID: Int64
    public let runID: RunID
    public let clauses: [ClauseVerificationRecord]

    public init(
        featureID: Int64, cycleID: Int64, route: String?, nightID: Int64, runID: RunID,
        clauses: [ClauseVerificationRecord]
    ) {
        self.featureID = featureID
        self.cycleID = cycleID
        self.route = route
        self.nightID = nightID
        self.runID = runID
        self.clauses = clauses
    }
}

extension JournalStore {
    /// Records `cycleID`'s Verification and its clauses (in the order given) in one transaction, first
    /// write wins. Returns whether this call inserted it — false means the Cycle was already verified and
    /// nothing was written.
    @discardableResult
    public func recordFeatureVerification(_ verification: NewFeatureVerification, now: Date = Date()) throws -> Bool {
        let (featureID, cycleID, route) = (verification.featureID, verification.cycleID, verification.route)
        let (nightID, runID, clauses) = (verification.nightID, verification.runID, verification.clauses)
        return try write { db in
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO feature_verification (feature_id, cycle_id, route, night_id, run_id, verified_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [featureID, cycleID, route, nightID, runID.rawValue, timestamp]
            )
            guard db.changesCount == 1 else { return false }
            let verificationID = db.lastInsertedRowID
            for (position, clause) in clauses.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO clause_verification (
                        verification_id, issue_id, cid, level, text, location_id, citation_provenance, verdict,
                        what_was_checked, interpretation, invalidated_cause, judged_by, position
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        verificationID, clause.issueID, clause.cid, clause.level, clause.text, clause.locationID,
                        clause.citationProvenance, clause.verdict.rawValue, clause.whatWasChecked,
                        clause.interpretation, clause.invalidatedCause, clause.judgedBy.rawValue, position
                    ]
                )
            }
            return true
        }
    }

    /// The Verification recorded for `cycleID`, with its clauses in report order; nil when none is.
    public func featureVerification(cycleID: Int64) throws -> FeatureVerificationRecord? {
        try read { db in
            let onError = { JournalError.featureVerificationUnreadable(cycleID: cycleID) }
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM feature_verification WHERE cycle_id = ?", arguments: [cycleID]
                )
            else {
                return nil
            }
            let id: Int64 = row["id"]
            let runIDText: String = row["run_id"]
            guard let runID = RunID(rawValue: runIDText) else { throw onError() }
            let clauseRows = try Row.fetchAll(
                db, sql: "SELECT * FROM clause_verification WHERE verification_id = ? ORDER BY position ASC",
                arguments: [id]
            )
            let clauses = try clauseRows.map { clause -> ClauseVerificationRecord in
                let verdictText: String = clause["verdict"]
                let judgedByText: String = clause["judged_by"]
                guard
                    let verdict = ClauseVerdict(rawValue: verdictText),
                    let judgedBy = ClauseJudge(rawValue: judgedByText)
                else {
                    throw onError()
                }
                return ClauseVerificationRecord(
                    issueID: clause["issue_id"], cid: clause["cid"], level: clause["level"], text: clause["text"],
                    locationID: clause["location_id"], citationProvenance: clause["citation_provenance"],
                    verdict: verdict, whatWasChecked: clause["what_was_checked"],
                    interpretation: clause["interpretation"], judgedBy: judgedBy,
                    invalidatedCause: clause["invalidated_cause"]
                )
            }
            return FeatureVerificationRecord(
                id: id, featureID: row["feature_id"], cycleID: cycleID, route: row["route"],
                nightID: row["night_id"], runID: runID,
                verifiedAt: try JournalStore.date(row["verified_at"], onError: onError), clauses: clauses
            )
        }
    }

    /// Every distinct Route any Attempt of `cycleID`'s Cards ran on — the Routes that wrote (or tried to
    /// write) the code Verification judges — in the order they were first used.
    public func attemptRoutes(cycleID: Int64) throws -> [Route] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT attempt.route_cli, attempt.route_model, attempt.route_effort
                FROM attempt JOIN card ON card.id = attempt.card_id
                WHERE card.cycle_id = ? ORDER BY attempt.id ASC
                """,
                arguments: [cycleID]
            )
            var seen: Set<Route> = []
            var ordered: [Route] = []
            for row in rows {
                guard let route = Route(cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"])
                else {
                    throw JournalError.featureVerificationUnreadable(cycleID: cycleID)
                }
                if seen.insert(route).inserted { ordered.append(route) }
            }
            return ordered
        }
    }
}
