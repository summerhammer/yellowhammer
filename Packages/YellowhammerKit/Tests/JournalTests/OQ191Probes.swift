import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// OQ191 (yellowhammer#708; spec ruling 2026-10-29, "a Cycle judges and publishes what it pushed"): thin adapters
// from the harness's own types to the production Journal API. Each probe names the ruling item and the spec
// anchor it serves, and calls the production code that builds it; the harness was written before that code, so
// its tests speak in these types rather than the production ones. A probe throws `OQ191NotBuilt` only when a
// fixture asks for something the production API cannot express.

extension Tag {
    /// The OQ191 harness. Declared once per test target: each target is its own module.
    @Tag static var oq191: Self
}

/// What a probe throws when a fixture asks for something the production API cannot express.
struct OQ191NotBuilt: Error, CustomStringConvertible {
    let item: String

    var description: String { "OQ191 \(item): not expressible" }
}

/// What the failure-injecting probe throws once the injected abort fired inside the record's transaction.
struct OQ191InjectedFailure: Error {}

/// The checkout a repository was judged in (item 7): a held Worktree, or a fresh checkout.
enum OQ191CheckoutKind: Equatable {
    case heldWorktree
    case freshCheckout
}

/// One repository's judged checkout, as the Verification record names it (items 3, 5 and 7).
struct OQ191JudgedCheckout: Equatable {
    let repository: String
    /// The judged commit; nil for a record written before this rule ("judged commit not recorded").
    let commit: String?
    /// nil when the record names no kind (a record written before this rule).
    let kind: OQ191CheckoutKind?
    /// Marked "no pushed branch" (item 5): a repository with the No-Pushed-Branch Outcome.
    let noPushedBranch: Bool
}

enum OQ191Probe {
    /// Item 2; `feature-authoring/stories/select-the-next-feature.md#pushed-tip`: records `commit` as the
    /// Pushed Tip of (`cycleID`, `repository`). Write-once per (Cycle, repository): a second write for the same
    /// pair either throws or is ignored, and never replaces the first.
    static func recordPushedTip(
        _ journal: JournalStore, cycleID: Int64, repository: String, commit: String, runID: RunID
    ) throws {
        try journal.recordPushedTip(cycleID: cycleID, repository: repository, commit: commit, runID: runID)
    }

    /// Item 2; `select-the-next-feature.md#pushed-tip`: the Pushed Tip recorded for (`cycleID`, `repository`);
    /// nil when none is recorded.
    static func pushedTip(_ journal: JournalStore, cycleID: Int64, repository: String) throws -> String? {
        try journal.pushedTip(cycleID: cycleID, repository: repository)
    }

    /// Items 3, 5 and 7; `verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout`: records
    /// `verification` with its judged checkouts, in the same transaction as the verdicts. Returns whether this
    /// call inserted it, as ``JournalStore/recordFeatureVerification(_:now:)`` does.
    @discardableResult
    static func recordFeatureVerification(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws -> Bool {
        try journal.recordFeatureVerification(verification.judging(judged))
    }

    /// Item 3; `verify-a-feature-clause-by-clause.md#judged-checkout` ("written in the same transaction as the
    /// verdicts"): the same write as ``recordFeatureVerification(_:_:judged:)``, with a failure injected at the
    /// judged-checkout write. The real body installs a trigger that raises `ABORT` on the first judged-checkout
    /// row, calls the real write, maps that abort to ``OQ191InjectedFailure`` and drops the trigger.
    static func recordFeatureVerificationAbortingJudgedCheckoutWrite(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws {
        let recorded = try verification.judging(judged)
        try journal.write { db in
            try db.execute(sql: """
            CREATE TRIGGER oq191_abort_judged_checkout BEFORE INSERT ON judged_checkout
            BEGIN SELECT RAISE(ABORT, 'oq191 injected judged checkout'); END
            """)
        }
        defer { try? journal.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS oq191_abort_judged_checkout") } }
        do {
            try journal.recordFeatureVerification(recorded)
        } catch {
            guard (error as? DatabaseError)?.message?.contains("oq191 injected judged checkout") == true else {
                throw error
            }
            throw OQ191InjectedFailure()
        }
    }

    /// Items 3, 5 and 7; `verify-a-feature-clause-by-clause.md#judged-checkout`: the judged checkouts the
    /// Cycle's Verification record names, sorted by repository; nil when no record names any.
    static func judgedCheckouts(_ journal: JournalStore, cycleID: Int64) throws -> [OQ191JudgedCheckout]? {
        guard let record = try journal.featureVerification(cycleID: cycleID), !record.judgedCheckouts.isEmpty else {
            return nil
        }
        return record.judgedCheckouts.map(OQ191JudgedCheckout.init)
    }
}

extension OQ191JudgedCheckout {
    /// The record's judged checkout as the harness compares it.
    init(_ checkout: JudgedCheckout) {
        let kind: OQ191CheckoutKind = switch checkout.kind {
        case .heldWorktree: .heldWorktree
        case .freshCheckout: .freshCheckout
        }
        self.init(
            repository: checkout.repository, commit: checkout.commit, kind: kind,
            noPushedBranch: checkout.noPushedBranch
        )
    }

    /// The judged checkout the record is written with; a probe value with no commit or no kind names a record
    /// from before the rule, which the write API cannot make.
    func recorded() throws -> JudgedCheckout {
        guard let commit, let kind else {
            throw OQ191NotBuilt(item: "fixture: a judged checkout to record needs a commit and a kind")
        }
        let recordedKind: JudgedCheckout.Kind = switch kind {
        case .heldWorktree: .heldWorktree
        case .freshCheckout: .freshCheckout
        }
        return JudgedCheckout(
            repository: repository, commit: commit, kind: recordedKind, noPushedBranch: noPushedBranch
        )
    }
}

extension NewFeatureVerification {
    /// `self` with the harness's judged checkouts.
    func judging(_ judged: [OQ191JudgedCheckout]) throws -> NewFeatureVerification {
        NewFeatureVerification(
            featureID: featureID, cycleID: cycleID, route: route, nightID: nightID, runID: runID, clauses: clauses,
            judgedCheckouts: try judged.map { try $0.recorded() }
        )
    }
}
