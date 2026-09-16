import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// P5.6: Clause reads and ordering

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

@Test("Clauses returns rows ordered by created_at ASC, cid ASC")
func clausesOrdered() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c2", "card", "second clause", "loc2", "machine-found", "machine-found",
                JournalStore.timestamp(epoch.addingTimeInterval(2))
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c1", "card", "first clause", "loc1", "machine-found", "machine-found",
                JournalStore.timestamp(epoch)
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c3", "card", "third clause", "loc3", "machine-found", "machine-found",
                JournalStore.timestamp(epoch.addingTimeInterval(2))
            ]
        )
    }

    let clauses = try journal.clauses(issueID: "issue-1")

    #expect(clauses.count == 3)
    #expect(clauses[0].cid == "c1")  // First by created_at
    #expect(clauses[1].cid == "c2")  // Second by created_at
    #expect(clauses[2].cid == "c3")  // Third by created_at, but cid is c3 > c2
}

@Test("Clauses excludes deleted rows")
func clausesExcludesDeleted() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c1", "card", "clause 1", "loc1", "machine-found", "machine-found",
                JournalStore.timestamp(epoch), 0
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c2", "card", "clause 2", "loc2", "machine-found", "machine-found",
                JournalStore.timestamp(epoch), 1
            ]
        )
    }

    let clauses = try journal.clauses(issueID: "issue-1")

    #expect(clauses.count == 1)
    #expect(clauses[0].cid == "c1")
}

@Test("RepoLaneLength counts Cards in cycle and repository")
func repoLaneLength() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID

        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID

        // Insert 3 cards in backend, 2 in frontend
        for index in 1...3 {
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, \
                budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, "issue-\(index)", "backend", "card", index, CardState.todo.rawValue, 0,
                    JournalStore.timestamp(epoch)
                ]
            )
        }
        for index in 1...2 {
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, \
                budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, "frontend-issue-\(index)", "frontend", "card", index,
                    CardState.todo.rawValue, 0, JournalStore.timestamp(epoch)
                ]
            )
        }
    }

    let backendLength = try journal.repoLaneLength(cycleID: 1, repository: "backend")
    let frontendLength = try journal.repoLaneLength(cycleID: 1, repository: "frontend")

    #expect(backendLength == 3)
    #expect(frontendLength == 2)
}

@Test("ClauseRecord round-trip preserves all fields")
func clauseRecordRoundTrip() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO clause (issue_id, cid, level, text, location_id, provenance, \
            citation_provenance, created_at, invalidated, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "issue-1", "c1", "card", "clause text", "loc1", "machine-found", "machine-found",
                JournalStore.timestamp(epoch), 0, 0
            ]
        )
    }

    let clauses = try journal.clauses(issueID: "issue-1")

    #expect(clauses.count == 1)
    let clause = clauses[0]
    #expect(clause.cid == "c1")
    #expect(clause.issueID == "issue-1")
    #expect(clause.level == "card")
    #expect(clause.text == "clause text")
    #expect(clause.locationID == "loc1")
    #expect(clause.provenance == "machine-found")
    #expect(clause.citationProvenance == "machine-found")
    #expect(clause.invalidated == false)
    #expect(clause.deleted == false)
}
