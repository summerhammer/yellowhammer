import ArgumentParser
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// shift-scheduling/fire-an-act-on-schedule: the author Act fires after every periodic land tick, and its
// trigger is true only with no Feature in flight — except on the Night's first author firing, which
// still runs the merge pass, the clocks and the settle gesture (select-the-next-feature).

@Suite("Periodic author firings")
struct PeriodicAuthorFiringTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// An open Cycle with one Done Card: a Feature in flight that the land Act has not archived yet.
    private func insertOpenCycle(_ journal: JournalStore) throws {
        try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
            )
            let featureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
                arguments: [featureID, JournalStore.timestamp(epoch)]
            )
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    db.lastInsertedRowID, "CARD-1", "main", "card", 1, CardState.done.rawValue, 0,
                    JournalStore.timestamp(epoch)
                ]
            )
        }
    }

    @Test("With a Cycle in flight the Night's first firing works and a later one idles without a board read")
    func laterFiringIdlesWithoutABoardRead() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        try insertOpenCycle(journal)
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        let worked = WorkCounter()

        func fire() async throws {
            try await EngineInvocation(
                act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .scheduled, runID: RunID(), board: board,
                work: { _ in worked.increment() }
            ).run()
        }

        try await fire()
        #expect(worked.count == 1, "the opening firing runs the Act's work although a Cycle is in flight")
        let readsAfterFirst = await reading.calls.count

        try await fire()
        try await fire()

        #expect(worked.count == 1)
        #expect(await reading.calls.count == readsAfterFirst, "an idle periodic firing reads nothing from the board")
        let idle = try journal.events(ofType: .actIdle)
        #expect(idle.count == 2)
        #expect(idle.allSatisfy { $0.event == .actIdle(reason: .featureInFlight) && $0.act == .author })
        #expect(try journal.events(ofType: .actEnded).count == 3)
    }

    @Test("A later firing after the Cycle archived works again")
    func laterFiringWorksAfterArchive() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        try insertOpenCycle(journal)
        let worked = WorkCounter()
        func fire() async throws {
            try await EngineInvocation(
                act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .scheduled, runID: RunID(), work: { _ in worked.increment() }
            ).run()
        }

        try await fire()
        try await fire()
        #expect(worked.count == 1)
        try journal.write { db in
            try db.execute(
                sql: "UPDATE cycle SET archived_at = ?", arguments: [JournalStore.timestamp(epoch)]
            )
        }
        try await fire()

        #expect(worked.count == 2)
    }

    @Test("An author firing that finds the Project Lease held records nothing and exits 0")
    func leaseHeldStandsDown() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        guard case .claimed(let holder) = try journal.claimActLease(act: .land, runID: RunID(), mode: .real) else {
            Issue.record("the land Act did not claim the Project")
            return
        }
        let eventsBefore = try journal.events().count
        var thrown: (any Error)?
        var lines: [String] = []

        do {
            try await ActLog.reportingFailure(
                of: AuthorCommand.self, now: { epoch }, write: { text, _ in lines.append(text) },
                body: {
                    try await EngineInvocation(
                        act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
                        trigger: .scheduled, runID: RunID(), work: { _ in Issue.record("must not work") }
                    ).run()
                }
            )
        } catch {
            thrown = error
        }

        #expect(thrown as? ExitCode == .success)
        #expect(lines.count == 1 && lines[0].hasPrefix("Stood down:"))
        // The only record is the stand-down itself: no Night opened, no Act started.
        let after = try journal.events()
        #expect(after.count == eventsBefore + 1)
        #expect(after.last?.event == .actStoodDown(holder: holder))
        #expect(try journal.currentNight() == nil)
    }
}

private final class WorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
