import Domain
import Foundation
import GRDB

// The No-Pushed-Branch Outcome's reads (glossary; risks OQ104, OQ107): a touched repository whose Repo
// Lane produced no completed work has its Feature Branch at its base, is never pushed and opens no pull
// request. It is recorded by a `noPushedBranchOutcome` event, and it takes the repository out of N — the
// set the merged fraction's denominator, the predecessor-ancestry gate and closure-by-merge read.
// `touchedRepositories(featureID:)` is the record of what the Feature was meant to touch and never shrinks.

extension JournalStore {
    /// The sorted repositories of `featureID`'s touched repositories whose Repo Lane has a recorded
    /// No-Pushed-Branch Outcome: a `noPushedBranchOutcome` event for this Feature (matched on its issue id)
    /// and no Worktree of this Feature and repository with a recorded `pushed_commit`. That second
    /// condition lets a later push supersede the record: a land firing can record the outcome and fault
    /// later, and the retry can find the lane has work after the Operator answered a Card.
    public func noPushedBranchRepositories(featureID: Int64) throws -> [String] {
        try read { db in try Self.noPushedBranchRepositories(db, featureID: featureID) }
    }

    static func noPushedBranchRepositories(_ db: Database, featureID: Int64) throws -> [String] {
        guard
            let issueID = try String.fetchOne(
                db, sql: "SELECT issue_id FROM feature WHERE id = ?", arguments: [featureID]
            )
        else {
            return []
        }
        let touched = Set(try Self.touchedRepositories(db, featureID: featureID))
        var recorded: Set<String> = []
        for record in try Self.events(db, ofType: .noPushedBranchOutcome) {
            guard case .noPushedBranchOutcome(_, let eventIssueID, let repository) = record.event else { continue }
            if eventIssueID == issueID, touched.contains(repository) { recorded.insert(repository) }
        }
        let pushed = try String.fetchAll(
            db,
            sql: "SELECT DISTINCT repository FROM worktree WHERE feature_id = ? AND pushed_commit IS NOT NULL",
            arguments: [featureID]
        )
        return recorded.subtracting(pushed).sorted()
    }

    /// Whether a `noPushedBranchOutcome` event for `featureID`'s Feature (matched on its issue id) and
    /// `repository` exists at all, whether or not a later push superseded it. The land Act's append-once
    /// check: unlike ``noPushedBranchRepositories(featureID:)`` it never forgets a superseded record, so a
    /// retried firing appends nothing for a repository that already has one.
    public func hasNoPushedBranchOutcomeRecord(featureID: Int64, repository: String) throws -> Bool {
        try read { db in
            guard
                let issueID = try String.fetchOne(
                    db, sql: "SELECT issue_id FROM feature WHERE id = ?", arguments: [featureID]
                )
            else {
                return false
            }
            return try Self.events(db, ofType: .noPushedBranchOutcome).contains { record in
                guard case .noPushedBranchOutcome(_, let eventIssueID, let eventRepository) = record.event else {
                    return false
                }
                return eventIssueID == issueID && eventRepository == repository
            }
        }
    }

    /// N: the sorted repositories `featureID`'s Cycle pushed a Feature Branch for, as the merged
    /// fraction's denominator, the predecessor-ancestry gate and closure-by-merge read them. Defined by
    /// subtraction — ``touchedRepositories(featureID:)`` minus ``noPushedBranchRepositories(featureID:)`` —
    /// so a Journal with no recorded No-Pushed-Branch Outcome reads N = touched, and a Rehearsal Night,
    /// whose push is a rehearsal boundary and records no outcome, keeps counting its lanes as the gate has
    /// always read them. Only a recorded No-Pushed-Branch Outcome takes a repository out of N. For a
    /// landed real-mode Cycle this equals the repositories that pushed a Feature Branch. It is a different
    /// read from `FeatureRollUp.pushedRepositories` (the literal recorded pushes, for lane headings).
    public func pushedRepositories(featureID: Int64) throws -> [String] {
        try read { db in try Self.pushedRepositories(db, featureID: featureID) }
    }

    static func pushedRepositories(_ db: Database, featureID: Int64) throws -> [String] {
        let outside = Set(try noPushedBranchRepositories(db, featureID: featureID))
        return try touchedRepositories(db, featureID: featureID).filter { !outside.contains($0) }
    }
}
