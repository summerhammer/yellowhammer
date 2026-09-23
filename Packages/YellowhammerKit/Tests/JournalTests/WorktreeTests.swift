import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// shift-scheduling/do-one-acts-work-and-exit: a Worktree's id and path are held in the Journal, one
// per (Feature, repository), so a resumed Act rebuilds Worktree paths from the Journal alone.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Inserts a fixture feature and returns its id.
private func insertFixtureFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

/// Claims the Act-scoped lease for `runID`, so writes under it revalidate.
private func claimLease(_ journal: JournalStore, runID: RunID, now: Date = epoch) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Test("recordWorktree without a held lease throws actLeaseLost")
func recordWorktreeWithoutLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
            runID: runID, now: epoch
        )
    }
}

@Test("releaseWorktree without a held lease throws actLeaseLost")
func releaseWorktreeWithoutLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    _ = try journal.releaseActLease(runID: runID)

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(1))
    }
}

@Test("A different run's held lease also blocks a Worktree write with actLeaseLost")
func recordWorktreeUnderAnotherRunsLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let holder = RunID()
    let other = RunID()
    try claimLease(journal, runID: holder)

    let holderLease = try journal.currentActLease()
    #expect(throws: JournalError.actLeaseLost(runID: other, holder: holderLease)) {
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
            runID: other, now: epoch
        )
    }
}

@Test("A fresh Feature has no Worktrees, and recording one returns it held")
func recordWorktreeSucceeds() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)

    #expect(try journal.worktrees(featureID: featureID).isEmpty)

    let recorded = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(recorded.isHeld)
    #expect(recorded.featureID == featureID)
    #expect(recorded.repository == "backend")
    #expect(recorded.worktreeID == "wt-1")
    #expect(recorded.path == "/tmp/wt-1")
    #expect(recorded.createdAt == JournalStore.stored(epoch))
}

@Test("Two Worktrees for one Feature (two repositories) read back in id order; releasing one flips isHeld")
func twoWorktreesReadBackAndOneReleases() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let first = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    let second = try journal.recordWorktree(
        featureID: featureID, repository: "spec", worktreeID: "wt-2", path: "/tmp/wt-2",
        runID: runID, now: epoch.addingTimeInterval(1)
    )

    let all = try journal.worktrees(featureID: featureID)
    #expect(all.map(\.id) == [first.id, second.id])
    #expect(all.allSatisfy { $0.isHeld })

    _ = try journal.recordWorktreePush(id: first.id, commit: "abc123", runID: runID, now: epoch.addingTimeInterval(2))
    let released = try journal.releaseWorktree(id: first.id, runID: runID, now: epoch.addingTimeInterval(3))
    #expect(!released.isHeld)
    #expect(released.releasedAt == JournalStore.stored(epoch.addingTimeInterval(3)))

    let afterRelease = try journal.worktrees(featureID: featureID)
    #expect(afterRelease.first { $0.id == first.id }?.isHeld == false)
    #expect(afterRelease.first { $0.id == second.id }?.isHeld == true)
}

@Test("Releasing an already-released Worktree throws worktreeReleased")
func releasingReleasedWorktreeThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    _ = try journal.recordWorktreePush(
        id: worktree.id, commit: "abc123", runID: runID, now: epoch.addingTimeInterval(1)
    )
    _ = try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(2))

    #expect(throws: JournalError.worktreeReleased(id: worktree.id)) {
        try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(3))
    }
}

@Test("Releasing an unpushed Worktree throws worktreeNotPushed and leaves it held")
func releasingUnpushedWorktreeThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )

    #expect(throws: JournalError.worktreeNotPushed(id: worktree.id)) {
        try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(1))
    }

    let all = try journal.worktrees(featureID: featureID)
    #expect(all.first { $0.id == worktree.id }?.isHeld == true)
}

@Test("recordWorktreePush sets pushedCommit, and releasing after it succeeds")
func recordWorktreePushThenRelease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(worktree.pushedCommit == nil)

    let pushed = try journal.recordWorktreePush(
        id: worktree.id, commit: "deadbeef", runID: runID, now: epoch.addingTimeInterval(1)
    )
    #expect(pushed.pushedCommit == "deadbeef")
    #expect(pushed.isHeld)

    let released = try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(2))
    #expect(!released.isHeld)
    #expect(released.pushedCommit == "deadbeef")
}

@Test("heldWorktree returns the held Worktree for a Feature's repository, and nil after release")
func heldWorktreeLookup() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)

    #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)

    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(try journal.heldWorktree(featureID: featureID, repository: "backend")?.id == worktree.id)
    #expect(try journal.heldWorktree(featureID: featureID, repository: "spec") == nil)

    _ = try journal.recordWorktreePush(
        id: worktree.id, commit: "abc123", runID: runID, now: epoch.addingTimeInterval(1)
    )
    _ = try journal.releaseWorktree(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(2))

    #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
}

@Test("A v7 database gains pushed_commit when the engine opens it")
func v7DatabaseGainsPushedCommitColumn() throws {
    let fixture = try JournalFixture()
    let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let v7 = try DatabaseQueue(path: fileURL.path)
    try JournalMigrations.migrator.migrate(v7, upTo: "v7-card-state-version")
    #expect(try v7.read { try $0.columns(in: "worktree") }.map(\.name).contains("pushed_commit") == false)

    let journal = try fixture.open()

    #expect(try journal.appliedMigrations().last == "v23-card-question")
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(worktree.pushedCommit == nil)
}

@Test("A v8 database gains the three reconciliation columns when the engine opens it")
func v8DatabaseGainsReconciliationColumns() throws {
    let fixture = try JournalFixture()
    let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let v8 = try DatabaseQueue(path: fileURL.path)
    try JournalMigrations.migrator.migrate(v8, upTo: "v8-worktree-pushed-commit")
    let v8Columns = try v8.read { try $0.columns(in: "worktree") }.map(\.name)
    #expect(!v8Columns.contains("last_known_good_commit"))
    #expect(!v8Columns.contains("wip_commit"))
    #expect(!v8Columns.contains("lost_at"))

    let journal = try fixture.open()

    #expect(try journal.appliedMigrations().last == "v23-card-question")
    let columns = try journal.read { try $0.columns(in: "worktree") }.map(\.name)
    #expect(columns.contains("last_known_good_commit"))
    #expect(columns.contains("wip_commit"))
    #expect(columns.contains("lost_at"))
}

@Test("recordWorktree stores lastKnownGoodCommit")
func recordWorktreeStoresLastKnownGoodCommit() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let recorded = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, lastKnownGoodCommit: "deadbeef", now: epoch
    )
    #expect(recorded.lastKnownGoodCommit == "deadbeef")
    #expect(recorded.wipCommit == nil)
    #expect(recorded.lostAt == nil)
    #expect(!recorded.isLost)
}

@Test("recordWorktreeKnownGood advances lastKnownGoodCommit and round-trips")
func recordWorktreeKnownGoodRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(worktree.lastKnownGoodCommit == nil)

    let advanced = try journal.recordWorktreeKnownGood(
        id: worktree.id, commit: "cafef00d", runID: runID, now: epoch.addingTimeInterval(1)
    )
    #expect(advanced.lastKnownGoodCommit == "cafef00d")

    let again = try journal.recordWorktreeKnownGood(
        id: worktree.id, commit: "0ddba11", runID: runID, now: epoch.addingTimeInterval(2)
    )
    #expect(again.lastKnownGoodCommit == "0ddba11")
}

@Test("recordWorktreeWIP sets wipCommit and round-trips")
func recordWorktreeWIPRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )
    #expect(worktree.wipCommit == nil)

    let recorded = try journal.recordWorktreeWIP(
        id: worktree.id, commit: "deadbeef", runID: runID, now: epoch.addingTimeInterval(1)
    )
    #expect(recorded.wipCommit == "deadbeef")
}

@Test("recordWorktreeLost clears held-ness, sets lostAt and releasedAt, and throws worktreeReleased on a second call")
func recordWorktreeLostClearsHeldness() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let worktree = try journal.recordWorktree(
        featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
        runID: runID, now: epoch
    )

    let lost = try journal.recordWorktreeLost(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(1))
    #expect(lost.isLost)
    #expect(!lost.isHeld)
    #expect(lost.lostAt == JournalStore.stored(epoch.addingTimeInterval(1)))
    #expect(lost.releasedAt == JournalStore.stored(epoch.addingTimeInterval(1)))
    #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)

    #expect(throws: JournalError.worktreeReleased(id: worktree.id)) {
        try journal.recordWorktreeLost(id: worktree.id, runID: runID, now: epoch.addingTimeInterval(2))
    }
}

@Test("An unknown Feature id throws featureUnknown; an unknown Worktree id throws worktreeUnknown")
func unknownFeatureAndWorktreeThrow() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    try claimLease(journal, runID: runID)

    #expect(throws: JournalError.featureUnknown(featureID: 999)) {
        try journal.recordWorktree(
            featureID: 999, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
            runID: runID, now: epoch
        )
    }
    #expect(throws: JournalError.worktreeUnknown(id: 999)) {
        try journal.releaseWorktree(id: 999, runID: runID, now: epoch)
    }
}
