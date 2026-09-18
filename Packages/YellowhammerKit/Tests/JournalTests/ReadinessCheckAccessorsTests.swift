import Domain
import Foundation
import Testing

@testable import Journal

// Journal-side accessors the Readiness Check builds on (roadmap P8.2).

private struct ReadinessFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-readiness-accessors-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }

    /// A Feature, Cycle and Card ready for readiness-related writes.
    func insertCard(journal: JournalStore, issueID: String = "issue-1") throws -> Int64 {
        try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: ["feature-1", "selected", JournalStore.timestamp(Date())]
            )
            let featureID: Int64 = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
                arguments: [featureID, JournalStore.timestamp(Date())]
            )
            let cycleID: Int64 = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, issueID, "backend", "card", 1, CardState.todo.rawValue, 0,
                    JournalStore.timestamp(Date())
                ]
            )
            return db.lastInsertedRowID
        }
    }
}

@Test("Transcription Blocks round-trip, including a voided stamp")
func transcriptionBlocksRoundTrip() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    let block = TranscriptionBlock(
        repository: "backend", paths: ["a.swift", "b.swift"], symbol: "Foo", mainlineCommit: "abc123",
        content: "func foo() {}", contentHash: "hash1", authorSupplied: false
    )
    try journal.recordTranscriptionBlocks(cardID: cardID, [block])

    let nightID = try journal.write { db in
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: ["fixture", "2026-09-15", "real", "open", JournalStore.timestamp(Date())]
        )
        return db.lastInsertedRowID
    }

    let rows = try journal.transcriptionBlocks(cardID: cardID)
    #expect(rows.count == 1)
    #expect(rows[0].repository == "backend")
    #expect(rows[0].paths == ["a.swift", "b.swift"])
    #expect(rows[0].symbol == "Foo")
    #expect(rows[0].mainlineCommit == "abc123")
    #expect(rows[0].content == "func foo() {}")
    #expect(rows[0].contentHash == "hash1")
    #expect(rows[0].authorSupplied == false)

    try journal.voidTranscriptionStamp(id: rows[0].id, nightID: nightID)
    let voided = try journal.transcriptionBlocks(cardID: cardID)
    #expect(voided[0].authorSupplied == true)
    #expect(voided[0].authorSuppliedNightID == nightID)
    #expect(voided[0].mainlineCommit == nil)
}

@Test("Architectural Brief prose upserts")
func architecturalBriefUpserts() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    #expect(try journal.architecturalBriefProse(cardID: cardID) == nil)

    try journal.recordArchitecturalBrief(cardID: cardID, prose: "First draft")
    #expect(try journal.architecturalBriefProse(cardID: cardID) == "First draft")

    try journal.recordArchitecturalBrief(cardID: cardID, prose: "Revised")
    #expect(try journal.architecturalBriefProse(cardID: cardID) == "Revised")
}

@Test("Clause insert, next id, invalidate, citation update and delete")
func clauseLifecycle() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    _ = try fixture.insertCard(journal: journal)

    #expect(try journal.nextClauseID(issueID: "issue-1") == "c1")

    try journal.insertClause(JournalStore.NewClause(
                    cid: "c1", issueID: "issue-1", level: "card", text: "clause one", locationID: "loc1",
                    provenance: "Author-supplied", citationProvenance: "Author-supplied"
                ))
    #expect(try journal.nextClauseID(issueID: "issue-1") == "c2")

    try journal.invalidateClause(issueID: "issue-1", cid: "c1", cause: "text_edited")
    var clauses = try journal.clauses(issueID: "issue-1")
    #expect(clauses[0].invalidated == true)
    #expect(clauses[0].invalidatedCause == "text_edited")

    try journal.updateClauseCitation(issueID: "issue-1", cid: "c1", locationID: "loc2")
    clauses = try journal.clauses(issueID: "issue-1")
    #expect(clauses[0].locationID == "loc2")
    #expect(clauses[0].citationProvenance == "Author-supplied")

    try journal.markClauseDeleted(issueID: "issue-1", cid: "c1")
    clauses = try journal.clauses(issueID: "issue-1")
    #expect(clauses.isEmpty)
}

@Test("nextClauseID considers deleted rows too")
func nextClauseIDConsidersDeleted() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    _ = try fixture.insertCard(journal: journal)

    try journal.insertClause(JournalStore.NewClause(
                    cid: "c5", issueID: "issue-1", level: "card", text: "t", locationID: "l",
                    provenance: "machine-found", citationProvenance: "machine-found"
                ))
    try journal.markClauseDeleted(issueID: "issue-1", cid: "c5")

    #expect(try journal.nextClauseID(issueID: "issue-1") == "c6")
}

@Test("A Card's declared scope is recorded, read back in order, and overwritten")
func declaredScopeRecordsReadsAndOverwrites() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    #expect(try journal.declaredScope(cardID: cardID).isEmpty)

    try journal.recordDeclaredScope(cardID: cardID, paths: ["Sources/App/", "Secrets/keys.env"])
    #expect(try journal.declaredScope(cardID: cardID) == ["Sources/App/", "Secrets/keys.env"])

    try journal.recordDeclaredScope(cardID: cardID, paths: ["Sources/Other/"])
    #expect(try journal.declaredScope(cardID: cardID) == ["Sources/Other/"])
}

@Test("Recording an empty declared scope clears it")
func declaredScopeCanBeCleared() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    try journal.recordDeclaredScope(cardID: cardID, paths: ["Sources/App/"])
    #expect(try journal.declaredScope(cardID: cardID) == ["Sources/App/"])

    try journal.recordDeclaredScope(cardID: cardID, paths: [])
    #expect(try journal.declaredScope(cardID: cardID).isEmpty)
}

@Test("Consecutive Divergences increment and reset")
func consecutiveDivergencesLifecycle() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    #expect(try journal.consecutiveDivergences(cardID: cardID) == 0)
    #expect(try journal.incrementConsecutiveDivergences(cardID: cardID) == 1)
    #expect(try journal.incrementConsecutiveDivergences(cardID: cardID) == 2)
    #expect(try journal.consecutiveDivergences(cardID: cardID) == 2)

    try journal.resetConsecutiveDivergences(cardID: cardID)
    #expect(try journal.consecutiveDivergences(cardID: cardID) == 0)
}
