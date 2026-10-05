import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// A Feature Branch is what Orca ADE reports at allocation, recorded per (Feature, repository), fixed
// once recorded.

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

private func insertFixtureFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Feature Branch store")
struct FeatureBranchStoreTests {
    @Test("a recorded Feature Branch reads back; an unrecorded pair reads nil")
    func recordedBranchReadsBack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == nil)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "rozd/yh-p-f")
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == "rozd/yh-p-f")
        #expect(try journal.featureBranch(featureID: featureID, repository: "mobile") == nil)
    }

    @Test("recording the same name again is a no-op")
    func sameNameIsNoOp() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == "yh-p-f")
    }

    @Test("a different name throws featureBranchConflict and keeps the recorded value")
    func differentNameConflicts() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        #expect(
            throws: JournalError.featureBranchConflict(
                featureID: featureID, repository: "backend", recorded: "yh-p-f", reported: "rozd/yh-p-f"
            )
        ) {
            try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "rozd/yh-p-f")
        }
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == "yh-p-f")
    }

    @Test("featureBranches reads a released Feature, per repository")
    func branchesReadAfterRelease() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "rozd/yh-p-f")
        try journal.recordFeatureBranch(featureID: featureID, repository: "mobile", branch: "yh-p-f")
        try journal.write { db in
            try Self.insertUnallocatedRepository(db, featureID: featureID, repository: "web")
        }
        try journal.markFeatureReleased(featureID: featureID)

        #expect(
            try journal.featureBranches(featureID: featureID) == ["backend": "rozd/yh-p-f", "mobile": "yh-p-f"]
        )
    }

    @Test("an unknown Feature throws featureUnknown")
    func unknownFeatureThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        #expect(throws: JournalError.featureUnknown(featureID: 99)) {
            try journal.recordFeatureBranch(featureID: 99, repository: "backend", branch: "yh-p-f")
        }
    }

    @Test("recordWorktree with a conflicting Feature Branch throws and writes no worktree row")
    func recordWorktreeConflictRollsBack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch) else {
            Issue.record("Could not claim the Act lease")
            return
        }
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")

        #expect(throws: JournalError.self) {
            try journal.recordWorktree(
                featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
                runID: runID, now: epoch, featureBranch: "rozd/yh-p-f"
            )
        }
        #expect(try journal.worktrees(featureID: featureID).isEmpty)

        let record = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
            runID: runID, now: epoch, featureBranch: "yh-p-f"
        )
        #expect(try journal.worktrees(featureID: featureID) == [record])
    }
}

extension FeatureBranchStoreTests {
    fileprivate static func insertUnallocatedRepository(
        _ db: Database, featureID: Int64, repository: String
    ) throws {
        try db.execute(
            sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
            arguments: [featureID, repository]
        )
    }
}
