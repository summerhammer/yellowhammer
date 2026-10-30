import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708; spec ruling 2026-10-29, "a Cycle judges and publishes what it pushed"): the API the
// land Act harness needs and `main` does not have yet. Each probe names the ruling item and the spec anchor it
// serves. Today each one returns nil or throws `OQ191NotBuilt`; the implementation PRs replace the bodies with
// real calls and keep the signatures, so the tests do not change. Production code is untouched.
//
// The Journal half of these probes (the Pushed Tip, the judged checkouts) is repeated in
// `Tests/JournalTests/OQ191Probes.swift`: each test target is its own module.

extension Tag {
    /// The OQ191 harness. Declared once per test target: each target is its own module.
    @Tag static var oq191: Self
}

/// What a probe throws until its behaviour is built.
struct OQ191NotBuilt: Error, CustomStringConvertible {
    let item: String

    var description: String { "OQ191 \(item): not built" }
}

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
    /// Item 2; `feature-authoring/stories/select-the-next-feature.md#pushed-tip`: the Pushed Tip the land Act
    /// recorded for (`cycleID`, `repository`); nil when none is recorded.
    static func pushedTip(_ journal: JournalStore, cycleID: Int64, repository: String) throws -> String? {
        nil
    }

    /// Items 3, 5 and 7; `verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout`: the judged
    /// checkouts the Cycle's Verification record names, sorted by repository; nil when no record names any.
    static func judgedCheckouts(_ journal: JournalStore, cycleID: Int64) throws -> [OQ191JudgedCheckout]? {
        nil
    }

    /// Items 3, 5 and 7; `verify-a-feature-clause-by-clause.md#judged-checkout`: records `verification` with its
    /// judged checkouts, in the same transaction as the verdicts (a pull request body fixture's setup).
    static func recordFeatureVerification(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws {
        throw OQ191NotBuilt(item: "item 3 (judged commit in the Verification record)")
    }

    /// Items 1, 2, 5, 6 and 9; `landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin`:
    /// every "not published" report the land Act made for `repository` — at Verification time and at release —
    /// as the text the Operator reads (Feature Card, Work Card or Night Summary), in the order made; nil when
    /// none is made.
    static func unpublishedCommitsReports(
        _ journal: JournalStore, board: FakeWritingBoard, repository: String
    ) async throws -> [String]? {
        nil
    }

    /// Item 4; `landing/stories/open-one-pull-request-per-repository.md#remote-tip-check`: the failure the remote
    /// tip check reported for `repository` (the remote branch at another commit, absent, or unreadable), as the
    /// text the Operator reads, in the order made; nil when none is made.
    static func remoteTipFailures(
        _ journal: JournalStore, board: FakeWritingBoard, repository: String
    ) async throws -> [String]? {
        nil
    }
}
