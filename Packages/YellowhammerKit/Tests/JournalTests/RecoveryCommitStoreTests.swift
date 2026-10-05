import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The recovery commit (OQ123): the Feature Branch tip a ghost-Worktree purge pinned at
// `refs/yellowhammer/recovery/<branch>`, recorded per (Feature, repository) before the purge and cleared
// by the allocation that verifies the re-created branch.

private struct RecoveryJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
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

private func insertFeature(_ journal: JournalStore) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Suite("Recovery commit store")
struct RecoveryCommitStoreTests {
    @Test("a recorded recovery commit reads back; an unrecorded pair reads nil")
    func recordedRecoveryCommitReadsBack() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")

        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == nil)
        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == "aaa111")
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "mobile") == nil)
    }

    @Test("recording the same recovery commit again is a no-op")
    func sameCommitIsNoOp() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")

        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == "aaa111")
    }

    @Test("a different recovery commit over a recorded one throws and keeps the first SHA")
    func differentCommitIsRefused() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )

        do {
            try journal.recordRecoveryCommit(
                featureID: featureID, repository: "backend", commit: "bbb222", runID: runID, now: epoch
            )
            Issue.record("expected recoveryCommitRefused")
        } catch let JournalError.recoveryCommitRefused(thrownFeature, repository, _) {
            #expect(thrownFeature == featureID)
            #expect(repository == "backend")
        }
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == "aaa111")
    }

    @Test("a recovery commit needs the pair's row and a recorded Feature Branch")
    func requiresARecordedBranch() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)

        // No row for the pair at all.
        #expect(throws: JournalError.self) {
            try journal.recordRecoveryCommit(
                featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
            )
        }

        // A row, but no Feature Branch recorded in it.
        try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, "backend"]
            )
        }
        #expect(throws: JournalError.self) {
            try journal.recordRecoveryCommit(
                featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
            )
        }
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == nil)
    }

    @Test("recording a Worktree clears only the recovery commit it names, in the same write")
    func recordWorktreeClearsOnlyAMatchingRecoveryCommit() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )

        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1", runID: runID,
            now: epoch, featureBranch: "yh-p-f", clearingRecoveryCommit: "bbb222"
        )
        #expect(
            try journal.recoveryCommit(featureID: featureID, repository: "backend") == "aaa111",
            "a different commit is never cleared"
        )

        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-2", path: "/tmp/wt-2", runID: runID,
            now: epoch, featureBranch: "yh-p-f", clearingRecoveryCommit: "aaa111"
        )
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == nil)
    }

    @Test("recording a Worktree with a conflicting Feature Branch rolls the recovery clear back too")
    func conflictingBranchKeepsTheRecoveryCommit() throws {
        let fixture = try RecoveryJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordRecoveryCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )

        #expect(throws: JournalError.self) {
            try journal.recordWorktree(
                featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1", runID: runID,
                now: epoch, featureBranch: "yh-p-f-2", clearingRecoveryCommit: "aaa111"
            )
        }
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == "aaa111")
        #expect(try journal.worktrees(featureID: featureID).isEmpty)
    }
}
