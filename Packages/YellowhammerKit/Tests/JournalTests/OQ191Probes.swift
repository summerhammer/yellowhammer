import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// OQ191 (yellowhammer#708; spec ruling 2026-10-29, "a Cycle judges and publishes what it pushed"): the Journal
// API the harness needs and `main` does not have yet. Each probe names the ruling item and the spec anchor it
// serves. Today each one returns nil or throws `OQ191NotBuilt`; the implementation PRs replace the bodies with
// real calls and keep the signatures, so the tests do not change. Production code is untouched.

extension Tag {
    /// The OQ191 harness. Declared once per test target: each target is its own module.
    @Tag static var oq191: Self
}

/// What a probe throws until its behaviour is built.
struct OQ191NotBuilt: Error, CustomStringConvertible {
    let item: String

    var description: String { "OQ191 \(item): not built" }
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
        throw OQ191NotBuilt(item: "item 2 (Pushed Tip per Cycle and repository)")
    }

    /// Item 2; `select-the-next-feature.md#pushed-tip`: the Pushed Tip recorded for (`cycleID`, `repository`);
    /// nil when none is recorded.
    static func pushedTip(_ journal: JournalStore, cycleID: Int64, repository: String) throws -> String? {
        nil
    }

    /// Items 3, 5 and 7; `verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout`: records
    /// `verification` with its judged checkouts, in the same transaction as the verdicts. Returns whether this
    /// call inserted it, as ``JournalStore/recordFeatureVerification(_:now:)`` does.
    @discardableResult
    static func recordFeatureVerification(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws -> Bool {
        throw OQ191NotBuilt(item: "item 3 (judged commit in the Verification record)")
    }

    /// Item 3; `verify-a-feature-clause-by-clause.md#judged-checkout` ("written in the same transaction as the
    /// verdicts"): the same write as ``recordFeatureVerification(_:_:judged:)``, with a failure injected at the
    /// judged-checkout write. The real body installs a trigger that raises `ABORT` on the first judged-checkout
    /// row, calls the real write, maps that abort to ``OQ191InjectedFailure`` and drops the trigger.
    static func recordFeatureVerificationAbortingJudgedCheckoutWrite(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws {
        throw OQ191NotBuilt(item: "item 3 (judged commit in the Verification transaction)")
    }

    /// Items 3, 5 and 7; `verify-a-feature-clause-by-clause.md#judged-checkout`: the judged checkouts the
    /// Cycle's Verification record names, sorted by repository; nil when no record names any.
    static func judgedCheckouts(_ journal: JournalStore, cycleID: Int64) throws -> [OQ191JudgedCheckout]? {
        nil
    }
}
