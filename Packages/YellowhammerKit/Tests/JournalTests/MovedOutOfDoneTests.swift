import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// board-projection / moved-out-of-done, D13: a Card detached by a move out of Done is an un-adopted Work Card
// whose elapsed-Nights count starts at the Night it was moved out of Done, not at the Night its Feature closed.

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private struct MovedOutFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-moved-out-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

@Test("A Card moved out of Done after its Feature closed counts Nights from the move, not from the closure")
func elapsedNightsStartAtTheMove() throws {
    let fixture = try MovedOutFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: base)
    let starts = try ["2026-09-23", "2026-09-24", "2026-09-25"].map { try #require(NightStart(rawValue: $0)) }
    let first = try journal.openNight(nightStart: starts[0], mode: .real, act: .author, runID: run, now: base).night
    let cardID = try insertDoneCard(journal)
    func lease(at offset: TimeInterval) throws {
        try journal.releaseActLease(runID: run)
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: base.addingTimeInterval(offset))
    }
    let cycleID = try journal.card(id: cardID).cycleID
    let featureID = try journal.read { db in
        try #require(try Int64.fetchOne(db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]))
    }
    try journal.archiveCycle(
        cycleID: cycleID, featureID: featureID, closedBy: .completion, runID: run, now: base.addingTimeInterval(60)
    )
    try lease(at: 100)
    _ = try journal.closeNight(
        id: first.id, reason: .nightEnd, act: .land, runID: run, now: base.addingTimeInterval(120)
    )
    try lease(at: day)
    let second = try journal.openNight(
        nightStart: starts[1], mode: .real, act: .author, runID: run, now: base.addingTimeInterval(day)
    ).night
    try lease(at: day + 30)
    _ = try journal.transitionCard(
        cardID: cardID, to: .blocked, blockReason: .movedOutOfDone, runID: run, act: .author, nightID: second.id,
        now: base.addingTimeInterval(day + 60)
    )
    try lease(at: day + 100)
    _ = try journal.closeNight(
        id: second.id, reason: .nightEnd, act: .land, runID: run, now: base.addingTimeInterval(day + 120)
    )
    try lease(at: 2 * day)
    _ = try journal.openNight(
        nightStart: starts[2], mode: .real, act: .author, runID: run, now: base.addingTimeInterval(2 * day)
    )

    // Closed at Night 1: without the move, Nights 2 and 3 would have elapsed.
    #expect(try journal.unadoptedNights(cardID: cardID, asOf: starts[2]) == 1)
}

private func insertDoneCard(_ journal: JournalStore) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-1", "selected", JournalStore.timestamp(base)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(base)]
        )
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                db.lastInsertedRowID, "CARD-1", "main", "card", 1, CardState.done.rawValue, 0,
                JournalStore.timestamp(base)
            ]
        )
        return db.lastInsertedRowID
    }
}
