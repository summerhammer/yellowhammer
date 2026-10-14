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

@Test("Transcription Blocks round-trip through the Journal")
func transcriptionBlocksRoundTrip() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)

    let block = TranscriptionBlock(
        repository: "backend", paths: ["a.swift", "b.swift"], symbol: "Foo", mainlineCommit: "abc123",
        content: "func foo() {}", contentHash: "hash1", authorSupplied: false
    )
    try journal.recordTranscriptionBlocks(cardID: cardID, [block])

    let rows = try journal.transcriptionBlocks(cardID: cardID)
    #expect(rows.count == 1)
    #expect(rows[0].repository == "backend")
    #expect(rows[0].paths == ["a.swift", "b.swift"])
    #expect(rows[0].symbol == "Foo")
    #expect(rows[0].mainlineCommit == "abc123")
    #expect(rows[0].content == "func foo() {}")
    #expect(rows[0].contentHash == "hash1")
    #expect(rows[0].authorSupplied == false)
    #expect(rows[0].authorSuppliedNight == nil)
    #expect(rows[0].isRead)
    #expect(rows[0].block.editedReference == nil)
}

@Test("An unread edited reference is replaced in, then read, keeping its Operator-supplied Night")
func unreadReferenceIsReadLater() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)
    let nightID = try journal.write { db in
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: ["fixture", "2026-09-15", "real", "open", JournalStore.timestamp(Date())]
        )
        return db.lastInsertedRowID
    }
    let line = "Contract: `backend` · `a.swift` lines 3–5 · commit `abc1234`"
    let kept = NewTranscriptionBlock(
        repository: "backend", paths: ["b.swift"], ranges: [:], symbol: nil, mainlineCommit: "def5678",
        content: "kept", contentHash: "h-kept", authorSupplied: false
    )
    let unread = NewTranscriptionBlock(
        repository: "backend", paths: ["a.swift"], ranges: ["a.swift": [LineRange(start: 3, end: 5)]],
        symbol: "Foo", mainlineCommit: nil, content: nil, contentHash: nil, authorSupplied: true,
        authorSuppliedNightID: nightID, referenceText: line
    )
    try journal.replaceTranscriptionBlocks(cardID: cardID, [kept, unread])

    let before = try journal.transcriptionBlocks(cardID: cardID)
    #expect(before.map(\.isRead) == [true, false])
    #expect(before[1].content == nil)
    #expect(before[1].contentHash == nil)
    #expect(before[1].referenceText == line)
    #expect(before[1].authorSuppliedNightID == nightID)
    #expect(before[1].authorSuppliedNight == NightStart(rawValue: "2026-09-15"))
    #expect(before[1].block.editedReference == line)
    #expect(before[1].block.content.isEmpty)
    #expect(before[0].block.editedReference == nil)

    try journal.recordTranscriptionRead(
        id: before[1].id, mainlineCommit: "abc1234deadbeef", ranges: ["a.swift": [LineRange(start: 3, end: 5)]],
        content: "c\nd\ne", contentHash: "h-read"
    )

    let after = try journal.transcriptionBlocks(cardID: cardID)
    #expect(after.map(\.isRead) == [true, true])
    #expect(after[1].content == "c\nd\ne")
    #expect(after[1].contentHash == "h-read")
    #expect(after[1].mainlineCommit == "abc1234deadbeef")
    #expect(after[1].ranges == ["a.swift": [LineRange(start: 3, end: 5)]])
    #expect(after[1].referenceText == nil)
    #expect(after[1].block.editedReference == nil)
    #expect(after[1].authorSupplied)
    #expect(after[1].authorSuppliedNightID == nightID)
    #expect(after[1].authorSuppliedNight == NightStart(rawValue: "2026-09-15"))
    #expect(after[0] == before[0])

    try journal.replaceTranscriptionBlocks(cardID: cardID, [])
    #expect(try journal.transcriptionBlocks(cardID: cardID).isEmpty)
}

@Test("A block's line ranges round-trip through the Journal, aligned with its paths, and a whole path has none")
func transcriptionBlockRangesRoundTrip() throws {
    let fixture = try ReadinessFixture()
    let journal = try fixture.open()
    let cardID = try fixture.insertCard(journal: journal)
    let ranged = TranscriptionBlock(
        repository: "api", paths: ["openapi.yaml", "models.swift", "notes.md"],
        ranges: [
            "openapi.yaml": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)],
            "notes.md": [LineRange(start: 7, end: 7)]
        ],
        symbol: nil, mainlineCommit: "abc123", content: "x", contentHash: "h", authorSupplied: false
    )
    let whole = TranscriptionBlock(
        repository: "api", paths: ["models.swift"], mainlineCommit: "abc123", content: "y",
        contentHash: "h2", authorSupplied: false
    )

    try journal.recordTranscriptionBlocks(cardID: cardID, [ranged, whole])

    let rows = try journal.transcriptionBlocks(cardID: cardID)
    #expect(rows[0].ranges == ranged.ranges)
    #expect(rows[0].block.ranges == ranged.ranges)
    #expect(rows[1].ranges.isEmpty)
    let stored: [String] = try journal.read { db in
        try String.fetchAll(db, sql: "SELECT ranges FROM transcription_block ORDER BY id")
    }
    #expect(stored == ["120-180+200-210\n-\n7-7", ""])
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
