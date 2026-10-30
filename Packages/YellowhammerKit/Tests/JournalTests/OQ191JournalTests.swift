import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// OQ191 (yellowhammer#708), Journal storage: the Pushed Tip is written once per (Cycle, repository), and the
// Verification record names each repository's judged commit and checkout kind in the same transaction as its
// verdicts. Spec at yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

private struct OQ191JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-oq191-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let commitB1 = String(repeating: "b1", count: 20)
private let commitB2 = String(repeating: "b2", count: 20)
private let baseM0 = String(repeating: "a0", count: 20)

/// A Feature with one Cycle touching backend and mobile, its Feature Branch recorded, and an open Night.
private struct OQ191World {
    let featureID: Int64
    let cycleID: Int64
    let nightID: Int64
    let runID: RunID
}

private func makeWorld(_ journal: JournalStore, projectID: ProjectID) throws -> OQ191World {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
        throw OQ191NotBuilt(item: "fixture: the land Act's lease could not be claimed")
    }
    let (featureID, cycleID, nightID) = try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [projectID.rawValue, "2026-10-29", "real", "open", JournalStore.timestamp(epoch)]
        )
        return (featureID, cycleID, db.lastInsertedRowID)
    }
    for repository in ["backend", "mobile"] {
        try journal.recordFeatureBranch(featureID: featureID, repository: repository, branch: "yh-proj-feat")
    }
    return OQ191World(featureID: featureID, cycleID: cycleID, nightID: nightID, runID: runID)
}

private func verification(_ world: OQ191World) -> NewFeatureVerification {
    NewFeatureVerification(
        featureID: world.featureID, cycleID: world.cycleID, route: "codex/gpt-5.4/high", nightID: world.nightID,
        runID: world.runID, clauses: [
            ClauseVerificationRecord(
                issueID: "BACK-1", cid: "c1", level: "card", text: "Returns 404.", locationID: "epic/story",
                citationProvenance: "machine-found", verdict: .met, whatWasChecked: "read the handler",
                interpretation: "path parameter", judgedBy: .agent
            )
        ]
    )
}

private let freshCheckouts = [
    OQ191JudgedCheckout(repository: "backend", commit: commitB1, kind: .freshCheckout, noPushedBranch: false),
    OQ191JudgedCheckout(repository: "mobile", commit: baseM0, kind: .freshCheckout, noPushedBranch: true)
]

@Suite("OQ191 Journal: the Pushed Tip and the judged commit", .tags(.oq191))
struct OQ191JournalTests {
    // feature-authoring/stories/select-the-next-feature.md#pushed-tip
    @Test(
        "item 2: a second Pushed Tip write in the same Cycle does not replace the first",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func pushedTipIsWriteOncePerCycle() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)

        try OQ191Probe.recordPushedTip(
            journal, cycleID: world.cycleID, repository: "backend", commit: commitB1, runID: world.runID
        )
        try? OQ191Probe.recordPushedTip(
            journal, cycleID: world.cycleID, repository: "backend", commit: commitB2, runID: world.runID
        )
        let tip = try OQ191Probe.pushedTip(journal, cycleID: world.cycleID, repository: "backend")
        #expect(tip == commitB1)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "items 3, 5, 7: the record names each repository's judged commit, checkout kind and no-pushed-branch mark",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func recordNamesJudgedCheckouts() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)

        withKnownIssue("OQ191 item 3: the Verification record names no judged commit") {
            try OQ191Probe.recordFeatureVerification(journal, verification(world), judged: freshCheckouts)
            #expect(try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) == freshCheckouts)
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 7: a record judged in held Worktrees names the kind held Worktree",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func recordNamesHeldWorktreeKind() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        let held = [
            OQ191JudgedCheckout(repository: "backend", commit: commitB1, kind: .heldWorktree, noPushedBranch: false)
        ]

        withKnownIssue("OQ191 item 7: the Verification record names no checkout kind") {
            try OQ191Probe.recordFeatureVerification(journal, verification(world), judged: held)
            #expect(try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) == held)
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 3: a failure at the judged-commit write leaves no verdict recorded (one transaction)",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func failedJudgedCheckoutWriteRecordsNoVerdict() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        #expect(try journal.featureVerification(cycleID: world.cycleID) == nil)

        withKnownIssue("OQ191 item 3: the judged commit is not written with the verdicts") {
            #expect(throws: OQ191InjectedFailure.self) {
                try OQ191Probe.recordFeatureVerificationAbortingJudgedCheckoutWrite(
                    journal, verification(world), judged: freshCheckouts
                )
            }
        }
        #expect(try journal.featureVerification(cycleID: world.cycleID) == nil)
        #expect(try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) == nil)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 3: a failure at the verdict write leaves no judged commit recorded (one transaction)",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func failedVerdictWriteRecordsNoJudgedCheckout() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        try journal.write { db in
            try db.execute(sql: """
            CREATE TRIGGER oq191_abort_verdicts BEFORE INSERT ON clause_verification
            BEGIN SELECT RAISE(ABORT, 'oq191 injected'); END
            """)
        }
        // The injection works: today's verdict write aborts on it and leaves nothing behind.
        #expect(throws: DatabaseError.self) { try journal.recordFeatureVerification(verification(world)) }
        #expect(try journal.featureVerification(cycleID: world.cycleID) == nil)

        withKnownIssue("OQ191 item 3: the judged commit is not written with the verdicts") {
            #expect(throws: DatabaseError.self) {
                try OQ191Probe.recordFeatureVerification(journal, verification(world), judged: freshCheckouts)
            }
        }
        #expect(try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) == nil)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 3: characterization: a record written before this rule names no judged commit, never landed_commit",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func recordBeforeTheRuleIsNotFilledFromLandedCommit() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        try journal.recordPushedTip(
            cycleID: world.cycleID, repository: "backend", commit: commitB2, runID: world.runID
        )
        #expect(try journal.pushedTip(cycleID: world.cycleID, repository: "backend") == commitB2)
        // Written through today's API, which records no judged checkout: a record from before this rule.
        #expect(try journal.recordFeatureVerification(verification(world)))

        let judged = try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) ?? []
        #expect(judged.allSatisfy { $0.commit == nil })
        #expect(!judged.contains { $0.commit == commitB2 })
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#one-recorded-verification
    @Test(
        "item 1, consequence: characterization: a second Verification record for the Cycle is not written",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func secondVerificationIsNotRecorded() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        #expect(try journal.recordFeatureVerification(verification(world)))
        let first = try #require(try journal.featureVerification(cycleID: world.cycleID))

        let second = NewFeatureVerification(
            featureID: world.featureID, cycleID: world.cycleID, route: "gemini/pro/high", nightID: world.nightID,
            runID: world.runID, clauses: []
        )
        #expect(try !journal.recordFeatureVerification(second))
        #expect(try journal.featureVerification(cycleID: world.cycleID) == first)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#one-recorded-verification
    @Test(
        "item 1, consequence: a second Verification record does not replace the judged commits of the first",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func secondVerificationKeepsTheFirstJudgedCommits() throws {
        let fixture = try OQ191JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        let moved = [
            OQ191JudgedCheckout(repository: "backend", commit: commitB2, kind: .heldWorktree, noPushedBranch: false)
        ]

        withKnownIssue("OQ191 item 3: the Verification record names no judged commit") {
            try OQ191Probe.recordFeatureVerification(journal, verification(world), judged: freshCheckouts)
            #expect(try !OQ191Probe.recordFeatureVerification(journal, verification(world), judged: moved))
            #expect(try OQ191Probe.judgedCheckouts(journal, cycleID: world.cycleID) == freshCheckouts)
        }
    }
}
