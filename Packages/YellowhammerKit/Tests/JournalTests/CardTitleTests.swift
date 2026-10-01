import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// issue #161; spec: landing/announce-a-partial-landing. `card.title` lets the Roll-up and the
// partial-landing PR body name a Card that did not complete by title rather than by issue id.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-card-title-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@discardableResult
private func insertFixtureCard(
    _ journal: JournalStore, issueID: String = "CARD-1", repository: String = "main", title: String? = nil
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, title, repository, kind, authored_order, state, budget_epoch,
            created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, title, repository, "card", 1, CardState.todo.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Card title (issue #161; spec: landing/announce-a-partial-landing)")
struct CardTitleTests {
    @Test("The card table has a title column")
    func cardTableHasTitleColumn() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        _ = try insertFixtureCard(journal)

        let columns = try journal.read { try $0.columns(in: "card") }.map(\.name)
        #expect(columns.contains("title"))
    }

    @Test("A Card with no recorded title reads nil, and displayTitle falls back to the issue id")
    func noTitleReadsNil() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cardID = try insertFixtureCard(journal, issueID: "CARD-1")

        let record = try journal.card(id: cardID)
        #expect(record.title == nil)
        #expect(record.displayTitle == "CARD-1")
    }

    @Test("displayTitle prefers a non-empty recorded title over the issue id")
    func displayTitlePrefersRecordedTitle() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cardID = try insertFixtureCard(journal, issueID: "CARD-1", title: "Fix the thing")

        let record = try journal.card(id: cardID)
        #expect(record.title == "Fix the thing")
        #expect(record.displayTitle == "Fix the thing")
    }

    @Test("updateCardTitle changes the recorded title under the Act-scoped lease")
    func updateCardTitleChangesTitle() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cardID = try insertFixtureCard(journal, issueID: "CARD-1", title: "Old title")
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch)

        let record = try journal.updateCardTitle(cardID: cardID, title: "New title", runID: runID, now: epoch)

        #expect(record.title == "New title")
        #expect(try journal.card(id: cardID).title == "New title")
    }

    @Test("updateCardTitle throws JournalError.cardUnknown for an unknown Card")
    func updateCardTitleUnknownCardThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch)

        #expect(throws: JournalError.cardUnknown(cardID: 999)) {
            try journal.updateCardTitle(cardID: 999, title: "New title", runID: runID, now: epoch)
        }
    }
}
