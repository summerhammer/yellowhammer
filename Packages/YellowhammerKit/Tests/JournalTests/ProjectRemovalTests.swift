import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Explicit Project removal (roadmap P13.5; spec risks OQ52(1)): `JournalStore.recordProjectRemoval(_:runID:now:)`.
// Slice 1 of 2 — the Journal module only; the `yh project remove` command (slice 2) is written against
// this API but is not built here.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-project-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
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
private let nightStart = NightStart(rawValue: "2026-09-24")!

private func cycleArchivedAt(_ journal: JournalStore, cycleID: Int64) throws -> String? {
    try journal.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT archived_at FROM cycle WHERE id = ?", arguments: [cycleID])
        return row?["archived_at"]
    }
}

private struct SeededProject {
    let featureID: Int64
    let cycleID: Int64
    let nightID: Int64
    let worktreeAlpha: WorktreeRecord
    let worktreeBeta: WorktreeRecord
}

/// One Feature with an open Cycle, an open Night, and two held Worktrees — claiming and releasing the
/// Act Lease along the way, the way a real Act sequence would.
@discardableResult
private func seedInFlightProject(_ journal: JournalStore) throws -> SeededProject {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
        struct SetupFailed: Error {}
        throw SetupFailed()
    }

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: runID, now: epoch)

    let (featureID, cycleID) = try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return (featureID, db.lastInsertedRowID)
    }

    let worktreeAlpha = try journal.recordWorktree(
        featureID: featureID, repository: "alpha", worktreeID: "wt-alpha", path: "/tmp/wt-alpha",
        runID: runID, now: epoch
    )
    let worktreeBeta = try journal.recordWorktree(
        featureID: featureID, repository: "beta", worktreeID: "wt-beta", path: "/tmp/wt-beta",
        runID: runID, now: epoch
    )

    try journal.releaseActLease(runID: runID)
    return SeededProject(
        featureID: featureID, cycleID: cycleID, nightID: opening.night.id,
        worktreeAlpha: worktreeAlpha, worktreeBeta: worktreeBeta
    )
}

@Test("Project removal closes the open Night, decommissions the in-flight slot, and releases named Worktrees")
func projectRemovalClosesAndDecommissions() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let seeded = try seedInFlightProject(journal)
    let removalRunID = RunID()

    let record = try journal.recordProjectRemoval(
        NewProjectRemoval(featureIssueID: "FEAT-1", releasedWorktreeIDs: [seeded.worktreeAlpha.id]),
        runID: removalRunID, now: epoch.addingTimeInterval(1_000)
    )

    #expect(record.closedNightIDs == [seeded.nightID])
    #expect(record.archivedCycleID == seeded.cycleID)
    #expect(record.releasedFeatureID == seeded.featureID)
    #expect(record.removedWorktrees == ["alpha"])
    #expect(record.keptWorktrees == ["beta"])

    let night = try #require(try journal.night(id: seeded.nightID))
    #expect(night.state == .closed)
    #expect(night.closeReason == .projectRemoved)

    #expect(try cycleArchivedAt(journal, cycleID: seeded.cycleID) != nil)

    let feature = try #require(try journal.feature(id: seeded.featureID))
    #expect(feature.releasedAt != nil)

    let worktrees = try journal.worktrees(featureID: seeded.featureID)
    let alpha = try #require(worktrees.first { $0.id == seeded.worktreeAlpha.id })
    let beta = try #require(worktrees.first { $0.id == seeded.worktreeBeta.id })
    #expect(alpha.releasedAt != nil)
    #expect(beta.releasedAt == nil)

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .nightClosed, .projectRemoved])

    guard case .projectRemoved(let featureIssueID, let removedWorktrees, let keptWorktrees) = events[2].event else {
        Issue.record("Event should be projectRemoved")
        return
    }
    #expect(featureIssueID == "FEAT-1")
    #expect(removedWorktrees == ["alpha"])
    #expect(keptWorktrees == ["beta"])
    #expect(events[2].nightID == seeded.nightID)
    #expect(events[2].act == nil)
}

@Test("Project removal is refused while an unexpired Act Lease is held, and writes nothing")
func projectRemovalRefusedWhileLeaseHeld() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let seeded = try seedInFlightProject(journal)

    let holderRunID = RunID()
    guard
        case .claimed(let holder) = try journal.claimActLease(
            act: .build, runID: holderRunID, mode: .real, now: epoch.addingTimeInterval(10)
        )
    else {
        Issue.record("Could not claim the Act lease")
        return
    }

    let removalRunID = RunID()
    await #expect(throws: JournalError.projectRemovalRefused(holder: holder)) {
        try journal.recordProjectRemoval(
            NewProjectRemoval(featureIssueID: "FEAT-1", releasedWorktreeIDs: [seeded.worktreeAlpha.id]),
            runID: removalRunID, now: epoch.addingTimeInterval(20)
        )
    }

    let night = try #require(try journal.night(id: seeded.nightID))
    #expect(night.state == .opened)
    #expect(try cycleArchivedAt(journal, cycleID: seeded.cycleID) == nil)
    #expect(try journal.events().map(\.type) == [.nightOpened])
}

@Test("Project removal proceeds past an expired Act Lease")
func projectRemovalProceedsPastExpiredLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let seeded = try seedInFlightProject(journal)

    let holderRunID = RunID()
    guard case .claimed = try journal.claimActLease(
        act: .build, runID: holderRunID, mode: .real, now: epoch.addingTimeInterval(10)
    ) else {
        Issue.record("Could not claim the Act lease")
        return
    }

    let removalRunID = RunID()
    let record = try journal.recordProjectRemoval(
        NewProjectRemoval(featureIssueID: "FEAT-1", releasedWorktreeIDs: [seeded.worktreeAlpha.id]),
        runID: removalRunID, now: epoch.addingTimeInterval(10).addingTimeInterval(LeasePolicy.ruled.timeToLive + 1)
    )

    #expect(record.closedNightIDs == [seeded.nightID])
    #expect(record.archivedCycleID == seeded.cycleID)
}

@Test("Project removal with no open Night and no open Cycle succeeds, closing and archiving nothing")
func projectRemovalWithNothingOpenSucceeds() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let removalRunID = RunID()
    let record = try journal.recordProjectRemoval(
        NewProjectRemoval(featureIssueID: nil, releasedWorktreeIDs: []), runID: removalRunID, now: epoch
    )

    #expect(record.closedNightIDs.isEmpty)
    #expect(record.archivedCycleID == nil)
    #expect(record.releasedFeatureID == nil)
    #expect(record.removedWorktrees.isEmpty)
    #expect(record.keptWorktrees.isEmpty)

    let events = try journal.events()
    #expect(events.map(\.type) == [.projectRemoved])
    guard case .projectRemoved(let featureIssueID, let removedWorktrees, let keptWorktrees) = events[0].event else {
        Issue.record("Event should be projectRemoved")
        return
    }
    #expect(featureIssueID == nil)
    #expect(removedWorktrees.isEmpty)
    #expect(keptWorktrees.isEmpty)
    #expect(events[0].nightID == nil)
}

@Test("heldWorktrees excludes released Worktrees")
func heldWorktreesExcludesReleased() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
    }
    let featureID: Int64 = try journal.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM feature WHERE issue_id = ?", arguments: ["FEAT-1"])!
    }

    let worktreeAlpha = try journal.recordWorktree(
        featureID: featureID, repository: "alpha", worktreeID: "wt-alpha", path: "/tmp/wt-alpha",
        runID: runID, now: epoch
    )
    _ = try journal.recordWorktree(
        featureID: featureID, repository: "beta", worktreeID: "wt-beta", path: "/tmp/wt-beta",
        runID: runID, now: epoch
    )
    _ = try journal.releaseWorktree(
        id: worktreeAlpha.id, runID: runID, discardingUnpushedWork: true, now: epoch
    )

    let held = try journal.heldWorktrees()
    #expect(held.map(\.repository) == ["beta"])
}
