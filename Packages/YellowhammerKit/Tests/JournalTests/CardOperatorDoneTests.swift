import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// board-projection / operator-done (ruling OQ199): the Journal write behind a Work Card the Operator moved
// to Done. The marker is the `.cardOperatorDone` event, not a card column.

private let operatorDoneEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private struct OperatorDoneFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-operator-done-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private func insertOperatorDoneCard(_ journal: JournalStore, state: CardState, stateVersion: Int = 0) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-1", "selected", JournalStore.timestamp(operatorDoneEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(operatorDoneEpoch)]
        )
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch,
            state_version, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                db.lastInsertedRowID, "CARD-1", "main", "card", 1, state.rawValue, 0, stateVersion,
                JournalStore.timestamp(operatorDoneEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Test("cardOperatorDone event round-trips with its previous reasons")
func cardOperatorDoneEventRoundTrips() throws {
    let fixture = try OperatorDoneFixture()
    let journal = try fixture.open()

    _ = try journal.append(
        .cardOperatorDone(
            cardID: 7, issueID: "ISSUE-1", previousState: .blocked, waitingReason: nil, blockReason: .featureCompleted
        ),
        act: .author, runID: RunID(), now: operatorDoneEpoch
    )

    let records = try journal.events(ofType: .cardOperatorDone)
    #expect(records.count == 1)
    guard case .cardOperatorDone(let cardID, let issueID, let previous, let waiting, let block) = records[0].event
    else {
        Issue.record("Event is not cardOperatorDone")
        return
    }
    #expect(cardID == 7)
    #expect(issueID == "ISSUE-1")
    #expect(previous == .blocked)
    #expect(waiting == nil)
    #expect(block == .featureCompleted)
}

@Test("markCardOperatorDone records Done, confirms the version on the board, and keeps the previous values")
func markCardOperatorDoneRecordsDone() throws {
    let fixture = try OperatorDoneFixture()
    let journal = try fixture.open()
    let runID = RunID()
    let cardID = try insertOperatorDoneCard(journal, state: .todo, stateVersion: 2)
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: operatorDoneEpoch)

    let done = try journal.markCardOperatorDone(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: operatorDoneEpoch
    )

    #expect(done.state == .done)
    #expect(done.stateVersion == 3)
    #expect(done.boardStateVersion == 3)
    #expect(try journal.cardsWithUnpostedState().isEmpty)
    #expect(try journal.isOperatorDone(cardID: cardID))
    guard case .cardOperatorDone(_, _, let previous, _, _)? = try journal.events(ofType: .cardOperatorDone).first?.event
    else {
        Issue.record("expected a cardOperatorDone event")
        return
    }
    #expect(previous == .todo)
}

@Test("markCardOperatorDone on a Done Card throws cardAlreadyDone")
func markCardOperatorDoneRefusesADoneCard() throws {
    let fixture = try OperatorDoneFixture()
    let journal = try fixture.open()
    let runID = RunID()
    let cardID = try insertOperatorDoneCard(journal, state: .done)
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: operatorDoneEpoch)

    #expect(throws: JournalError.cardAlreadyDone(cardID: cardID)) {
        try journal.markCardOperatorDone(
            cardID: cardID, runID: runID, act: .author, nightID: nil, now: operatorDoneEpoch
        )
    }
    #expect(try !journal.isOperatorDone(cardID: cardID))
}

@Test("markCardOperatorDone without the Act lease throws actLeaseLost")
func markCardOperatorDoneNeedsTheLease() throws {
    let fixture = try OperatorDoneFixture()
    let journal = try fixture.open()
    let cardID = try insertOperatorDoneCard(journal, state: .todo)

    #expect(throws: JournalError.self) {
        try journal.markCardOperatorDone(
            cardID: cardID, runID: RunID(), act: .author, nightID: nil, now: operatorDoneEpoch
        )
    }
}

@Test("A Yellowhammer Done is not Operator Done, and a Card that left Operator Done is not either")
func isOperatorDoneReadsTheLatestDoneEntry() throws {
    let fixture = try OperatorDoneFixture()
    let journal = try fixture.open()
    let runID = RunID()
    let cardID = try insertOperatorDoneCard(journal, state: .todo)
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: operatorDoneEpoch)

    _ = try journal.transitionCard(cardID: cardID, to: .done, runID: runID, act: .build, nightID: nil)
    #expect(try !journal.isOperatorDone(cardID: cardID))

    let other = try insertOperatorDoneCardInSameJournal(journal)
    _ = try journal.markCardOperatorDone(cardID: other, runID: runID, act: .build, nightID: nil)
    #expect(try journal.isOperatorDone(cardID: other))
    #expect(try !journal.isOperatorDone(cardID: cardID))

    _ = try journal.transitionCard(cardID: other, to: .todo, runID: runID, act: .build, nightID: nil)
    #expect(try !journal.isOperatorDone(cardID: other))
}

private func insertOperatorDoneCardInSameJournal(_ journal: JournalStore) throws -> Int64 {
    try journal.write { db in
        let cycleID = try Int64.fetchOne(db, sql: "SELECT id FROM cycle LIMIT 1") ?? 1
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, "CARD-2", "main", "card", 2, CardState.todo.rawValue, 0,
                JournalStore.timestamp(operatorDoneEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}
