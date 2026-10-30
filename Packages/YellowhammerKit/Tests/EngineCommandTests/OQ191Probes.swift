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
        try journal.pushedTip(cycleID: cycleID, repository: repository)
    }

    /// Items 3, 5 and 7; `verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout`: the judged
    /// checkouts the Cycle's Verification record names, sorted by repository; nil when no record names any.
    static func judgedCheckouts(_ journal: JournalStore, cycleID: Int64) throws -> [OQ191JudgedCheckout]? {
        guard let record = try journal.featureVerification(cycleID: cycleID), !record.judgedCheckouts.isEmpty else {
            return nil
        }
        return record.judgedCheckouts.map(OQ191JudgedCheckout.init)
    }

    /// Items 3, 5 and 7; `verify-a-feature-clause-by-clause.md#judged-checkout`: records `verification` with its
    /// judged checkouts, in the same transaction as the verdicts (a pull request body fixture's setup).
    static func recordFeatureVerification(
        _ journal: JournalStore, _ verification: NewFeatureVerification, judged: [OQ191JudgedCheckout]
    ) throws {
        try journal.recordFeatureVerification(verification.judging(judged))
    }

    /// Items 1, 2, 5, 6 and 9; `landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin`:
    /// every "not published" report the land Act made for `repository` — at Verification time and at release —
    /// as the text the Operator reads (Feature Card, Work Card or Night Summary), in the order made; nil when
    /// none is made.
    static func unpublishedCommitsReports(
        _ journal: JournalStore, board: FakeWritingBoard, repository: String
    ) async throws -> [String]? {
        // The Feature Card's comments: both reports are posted there, in the order made.
        let featureIssue = try #require(try journal.inFlightFeature()).feature.issueID
        let reports = await board.comments
            .filter { $0.issue.rawValue == featureIssue && $0.body.hasPrefix("Not published: ") }
            .map(\.body)
            .filter { $0.contains(" in \(repository) ") || $0.contains(" in \(repository), ") }
        return reports.isEmpty ? nil : reports
    }

    /// Item 4; `landing/stories/open-one-pull-request-per-repository.md#remote-tip-check`: the failure the remote
    /// tip check reported for `repository` (the remote branch at another commit, absent, or unreadable), as the
    /// text the Operator reads, in the order made; nil when none is made.
    static func remoteTipFailures(
        _ journal: JournalStore, board: FakeWritingBoard, repository: String
    ) async throws -> [String]? {
        // The Feature Card's comments: the remote tip check reports each failure there, in the order made.
        let featureIssue = try #require(try journal.inFlightFeature()).feature.issueID
        let failures = await board.comments
            .filter { $0.issue.rawValue == featureIssue && $0.body.hasPrefix("Not landed: the remote branch ") }
            .map(\.body)
            .filter { $0.contains(" in \(repository) ") }
        return failures.isEmpty ? nil : failures
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
