import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// routing/resolve-a-route-for-a-card (P7.6): the attempt-history exclusion set resolution filters by
// is the Journal's `route_exclusion` rows for the Card's current budget epoch. An Override pinned in
// triage resets the epoch (P7.7), so an earlier epoch's rows no longer exclude.

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

private func insertFixtureCard(_ journal: JournalStore, budgetEpoch: Int) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["ENG-1", "selected", JournalStore.timestamp(epoch)]
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
            arguments: [
                cycleID, "ENG-1", "backend", "impl", 1, CardState.todo.rawValue, budgetEpoch,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

private func exclude(_ journal: JournalStore, cardID: Int64, epoch budgetEpoch: Int, _ route: Route) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO route_exclusion
            (card_id, budget_epoch, route_cli, route_model, route_effort, reason, excluded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cardID, budgetEpoch, route.cli, route.model, route.effort, "hard failure", JournalStore.timestamp(epoch)
            ]
        )
    }
}

private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!

@Test("A fresh Card excludes nothing")
func freshCardExcludesNothing() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, budgetEpoch: 0)

    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
}

@Test("Only the current budget epoch's exclusions apply")
func onlyTheCurrentEpochExcludes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, budgetEpoch: 1)
    try exclude(journal, cardID: cardID, epoch: 0, routeA)
    try exclude(journal, cardID: cardID, epoch: 1, routeB)

    #expect(try journal.excludedRoutes(cardID: cardID) == [routeB])
    // The whole history still lists both, in order — the epoch scoping is resolution's, not the record's.
    #expect(try journal.attemptHistory(cardID: cardID).excludedRoutes == [routeA, routeB])
}

@Test("An unknown Card is refused, not read as excluding nothing")
func unknownCardIsRefused() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(throws: JournalError.cardUnknown(cardID: 42)) {
        try journal.excludedRoutes(cardID: 42)
    }
}
