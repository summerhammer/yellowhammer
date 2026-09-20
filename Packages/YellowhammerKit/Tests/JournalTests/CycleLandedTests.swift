import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.1; risks OQ8 (once per Cycle): `cycle.landed_at` (v16-cycle-landed) and
// `JournalStore.markCycleLanded(cycleID:runID:now:)` / `isCycleLanded(cycleID:)`.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-cycle-landed-\(UUID().uuidString)", directoryHint: .isDirectory)
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

private func insertFixtureCycle(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("v16-cycle-landed migration")
struct CycleLandedMigrationTests {
    @Test("v16-cycle-landed is applied and adds cycle.landed_at")
    func v16IsAppliedAndAddsColumn() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().contains("v16-cycle-landed"))
        #expect(JournalStore.migrationIdentifiers.contains("v16-cycle-landed"))

        let cycleID = try insertFixtureCycle(journal, issueID: "FEAT-1")
        #expect(try journal.isCycleLanded(cycleID: cycleID) == false)
    }
}

@Suite("markCycleLanded / isCycleLanded")
struct MarkCycleLandedTests {
    @Test("marks a Cycle landed once")
    func marksLandedOnce() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cycleID = try insertFixtureCycle(journal, issueID: "FEAT-1")
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("Could not claim the Act lease")
            return
        }

        #expect(try journal.isCycleLanded(cycleID: cycleID) == false)
        try journal.markCycleLanded(cycleID: cycleID, runID: runID, now: epoch)
        #expect(try journal.isCycleLanded(cycleID: cycleID))
    }

    @Test("landing an already-landed Cycle throws cycleAlreadyLanded")
    func alreadyLandedThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cycleID = try insertFixtureCycle(journal, issueID: "FEAT-1")
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("Could not claim the Act lease")
            return
        }
        try journal.markCycleLanded(cycleID: cycleID, runID: runID, now: epoch)

        #expect(throws: JournalError.cycleAlreadyLanded(cycleID: cycleID)) {
            try journal.markCycleLanded(cycleID: cycleID, runID: runID, now: epoch)
        }
    }

    @Test("landing an unknown Cycle throws cycleUnknown")
    func unknownCycleThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("Could not claim the Act lease")
            return
        }

        #expect(throws: JournalError.cycleUnknown(cycleID: 999)) {
            try journal.markCycleLanded(cycleID: 999, runID: runID, now: epoch)
        }
    }

    @Test("a foreign runID cannot mark a Cycle landed: lease revalidation refuses it")
    func foreignRunIDRefused() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cycleID = try insertFixtureCycle(journal, issueID: "FEAT-1")
        let holderRunID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: holderRunID, mode: .real, now: epoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }

        let foreignRunID = RunID()
        #expect(throws: JournalError.self) {
            try journal.markCycleLanded(cycleID: cycleID, runID: foreignRunID, now: epoch)
        }
        #expect(try journal.isCycleLanded(cycleID: cycleID) == false)
    }
}
