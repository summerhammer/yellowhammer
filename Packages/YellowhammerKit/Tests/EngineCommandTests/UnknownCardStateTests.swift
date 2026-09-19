import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-unknown-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - Unknown Card State

// `card.state` is written only by us, from CardState, so a value outside that vocabulary means the
// Journal is inconsistent. Counting such a row as finished would let the land Act fire over work
// nobody could classify, so both reads stop and name the row instead.

/// Inserts a Feature → Cycle → Card chain whose Card carries a `state` outside the `CardState`
/// vocabulary, and returns the Cycle's id.
private func insertCardWithUnknownState(_ journal: JournalStore, state: String) throws -> Int64 {
    try journal.write { db -> Int64 in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["CARD-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID

        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID

        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, "CARD-1", "main", "card", 1, state, 0, JournalStore.timestamp(epoch)]
        )
        return cycleID
    }
}

@Test("A Card state outside the vocabulary stops the Project-wide read and names the Card")
func unknownStateProjectWideThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    _ = try insertCardWithUnknownState(journal, state: "pending")

    #expect(throws: JournalError.unknownCardState(cardID: 1, state: "pending")) {
        _ = try journal.unfinishedCardCount()
    }
}

@Test("A Card state outside the vocabulary stops the Cycle-scoped read and names the Card")
func unknownStateCycleScopedThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cycleID = try insertCardWithUnknownState(journal, state: "corrupted")

    #expect(throws: JournalError.unknownCardState(cardID: 1, state: "corrupted")) {
        _ = try journal.unfinishedCardCount(cycleID: cycleID)
    }
}

@Test("A Card state outside the vocabulary stops every Act's trigger", arguments: Act.allCases)
func unknownStateStopsEveryTrigger(_ act: Act) throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    _ = try insertCardWithUnknownState(journal, state: "pending")

    #expect(throws: JournalError.unknownCardState(cardID: 1, state: "pending")) {
        _ = try ActTriggerPredicate.evaluate(act: act, trigger: .scheduled, journal: journal)
    }
}
