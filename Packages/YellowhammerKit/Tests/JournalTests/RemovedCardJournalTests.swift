import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// OQ142: a Work Card whose issue was trashed, or archived while it was in play, is set aside. The
// Journal reads that decide the land gate, the lane holes, the unposted board state and the
// unanswered-Nights clock all leave it out — and take it back, unchanged, once it is restored.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private struct World {
    let journal: JournalStore
    let runID = RunID()
    let cycleID: Int64
    let nightID: Int64

    init(_ journal: JournalStore) throws {
        self.journal = journal
        cycleID = try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
            )
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
                arguments: [db.lastInsertedRowID, JournalStore.timestamp(epoch)]
            )
            return db.lastInsertedRowID
        }
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch)
        else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        nightID = try journal.openNight(
            nightStart: NightStart(rawValue: "2026-09-20")!, mode: .rehearsal, act: .build, runID: runID, now: epoch
        ).night.id
    }

    func insertCard(_ issueID: String, state: CardState, order: Int) throws -> Int64 {
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, issueID, "backend", "impl", order, state.rawValue, 0, JournalStore.timestamp(epoch)
                ]
            )
            return db.lastInsertedRowID
        }
    }

    func remove(_ cardID: Int64, how: CardRemoval = .trashed) throws {
        try journal.markCardRemovedFromBoard(
            cardID: cardID, how: how, runID: runID, act: .build, nightID: nightID, now: epoch
        )
    }

    func restore(_ cardID: Int64) throws {
        try journal.restoreCardToBoard(cardID: cardID, runID: runID, act: .build, nightID: nightID, now: epoch)
    }
}

@Suite("Journal reads set a removed Work Card aside (OQ142)")
struct RemovedCardJournalTests {
    @Test("A removed Todo or In Progress Card is not unfinished, in either count; restored, it is again")
    func unfinishedCountsLeaveOutARemovedCard() throws {
        let fixture = try JournalFixture()
        let world = try World(try fixture.open())
        let todo = try world.insertCard("ENG-1", state: .todo, order: 1)
        let inProgress = try world.insertCard("ENG-2", state: .inProgress, order: 2)
        _ = try world.insertCard("ENG-3", state: .todo, order: 3)
        #expect(try world.journal.unfinishedCardCount() == 3)

        try world.remove(todo)
        try world.remove(inProgress, how: .archived)
        #expect(try world.journal.unfinishedCardCount() == 1)
        #expect(try world.journal.unfinishedCardCount(cycleID: world.cycleID) == 1)

        try world.restore(todo)
        #expect(try world.journal.unfinishedCardCount() == 2)
        #expect(try world.journal.unfinishedCardCount(cycleID: world.cycleID) == 2)
    }

    @Test("A removed Blocked or Waiting on You Card is not a lane hole")
    func laneHolesLeaveOutARemovedCard() throws {
        let fixture = try JournalFixture()
        let world = try World(try fixture.open())
        let blocked = try world.insertCard("ENG-1", state: .blocked, order: 1)
        let waiting = try world.insertCard("ENG-2", state: .waitingOnYou, order: 2)
        #expect(try world.journal.laneHoles(cycleID: world.cycleID).map(\.id) == [blocked, waiting])

        try world.remove(blocked)
        #expect(try world.journal.laneHoles(cycleID: world.cycleID).map(\.id) == [waiting])
    }

    @Test("A removed Card's unposted board state is not replayed, and is kept for a restore")
    func unpostedStateLeavesOutARemovedCard() throws {
        let fixture = try JournalFixture()
        let world = try World(try fixture.open())
        let cardID = try world.insertCard("ENG-1", state: .todo, order: 1)
        _ = try world.journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .routeFailure, runID: world.runID, act: .build,
            nightID: world.nightID, now: epoch
        )
        #expect(try world.journal.cardsWithUnpostedState().map(\.id) == [cardID])

        try world.remove(cardID)
        #expect(try world.journal.cardsWithUnpostedState().isEmpty)

        try world.restore(cardID)
        #expect(try world.journal.cardsWithUnpostedState().map(\.id) == [cardID])
    }

    @Test("A removed Waiting on You Card's clock neither advances nor fires; restored, it resumes unchanged")
    func unansweredClockIsSuspendedWhileRemoved() throws {
        let fixture = try JournalFixture()
        let world = try World(try fixture.open())
        let cardID = try world.insertCard("ENG-1", state: .todo, order: 1)
        _ = try world.journal.transitionCard(
            cardID: cardID, to: .waitingOnYou, waitingReason: .question, runID: world.runID, act: .build,
            nightID: world.nightID, now: epoch
        )
        let night2 = try openNight(world, "2026-09-21", dayOffset: 1)
        _ = try advance(world, night: night2)
        #expect(try world.journal.card(id: cardID).unansweredNights == 1)

        try world.remove(cardID)
        let night3 = try openNight(world, "2026-09-22", dayOffset: 2)
        let night4 = try openNight(world, "2026-09-23", dayOffset: 3)
        #expect(try advance(world, night: night3).isEmpty)
        #expect(try advance(world, night: night4).isEmpty)
        #expect(try world.journal.card(id: cardID).unansweredNights == 1, "suspended, not advanced and not reset")
        #expect(try world.journal.cardsPastUnansweredBound(cycleIDs: [world.cycleID], unansweredNightsMax: 0).isEmpty)
        #expect(try world.journal.landedCycleIDsWithWaitingOnYouCards().isEmpty)

        try world.restore(cardID)
        #expect(try world.journal.card(id: cardID).unansweredNights == 1, "restored with its count unchanged")
        #expect(try world.journal.card(id: cardID).state == .waitingOnYou)
        let night5 = try openNight(world, "2026-09-24", dayOffset: 4)
        #expect(try advance(world, night: night5).map(\.id) == [cardID], "past a bound of 1, it fires again")
        #expect(try world.journal.card(id: cardID).unansweredNights == 2)
    }

    private func openNight(_ world: World, _ start: String, dayOffset: Int) throws -> Int64 {
        let now = epoch.addingTimeInterval(TimeInterval(dayOffset) * 86_400)
        guard case .claimed = try world.journal.claimActLease(
            act: .build, runID: world.runID, mode: .rehearsal, now: now
        ) else {
            throw JournalError.actLeaseLost(runID: world.runID, holder: nil)
        }
        return try world.journal.openNight(
            nightStart: NightStart(rawValue: start)!, mode: .rehearsal, act: .build, runID: world.runID, now: now
        ).night.id
    }

    private func advance(_ world: World, night: Int64) throws -> [CardRecord] {
        try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
    }
}
