import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// loop-state/record-failure-cause-recurrence (roadmap P8.8): the count lives against the Card in this
// Project's Journal, spans separate Nights, and is never joined to a sibling Project's.

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
private let firstNight = NightStart(rawValue: "2026-09-15")!
private let secondNight = NightStart(rawValue: "2026-09-16")!
private let exitTwo = FailureCause(ending: .hardFailure(.exitStatus(2)))!
private let signaled = FailureCause(ending: .crashedUnknown(.signaled(9)))!

private func insertFixtureCards(_ journal: JournalStore, issueIDs: [String] = ["ENG-1"]) throws -> [Int64] {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [db.lastInsertedRowID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        return try issueIDs.enumerated().map { index, issueID in
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, issueID, "backend", "impl", index + 1, CardState.todo.rawValue, 0,
                    JournalStore.timestamp(epoch)
                ]
            )
            return db.lastInsertedRowID
        }
    }
}

/// A Journal with its Cards, a held Act Lease and two Nights of this Project.
private struct Nights {
    let journal: JournalStore
    let runID = RunID()
    let cardIDs: [Int64]
    let first: Int64
    let second: Int64

    init(_ journal: JournalStore, issueIDs: [String] = ["ENG-1"]) throws {
        self.journal = journal
        cardIDs = try insertFixtureCards(journal, issueIDs: issueIDs)
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        first = try journal.openNight(nightStart: firstNight, mode: .rehearsal, act: .build, runID: runID, now: epoch)
            .night.id
        second = try journal.openNight(nightStart: secondNight, mode: .rehearsal, act: .build, runID: runID, now: epoch)
            .night.id
    }

    func record(_ cause: FailureCause, card: Int = 0, night: Int64) throws -> FailureCauseRecord {
        try journal.recordFailureCause(
            cardID: cardIDs[card], cause: cause, nightID: night, runID: runID, act: .build, now: epoch
        )
    }
}

@Suite("Failure-Cause Recurrence in the Journal (P8.8)")
struct FailureCauseRecurrenceTests {
    @Test("A first occurrence counts 1, and a second failure of the same cause within the Night leaves it at 1")
    func withinOneNightIsOneOccurrence() throws {
        let fixture = try JournalFixture()
        let nights = try Nights(try fixture.open())

        #expect(try nights.record(exitTwo, night: nights.first).recurrenceCount == 1)
        let again = try nights.record(exitTwo, night: nights.first)
        #expect(again.recurrenceCount == 1)
        #expect(!again.hasRecurred)
    }

    @Test("The same cause on a separate Night is a recurrence, and the row remembers both Nights")
    func aSeparateNightRecurs() throws {
        let fixture = try JournalFixture()
        let nights = try Nights(try fixture.open())

        _ = try nights.record(exitTwo, night: nights.first)
        let recurred = try nights.record(exitTwo, night: nights.second)

        #expect(recurred.recurrenceCount == 2)
        #expect(recurred.hasRecurred)
        #expect(recurred.firstNightID == nights.first)
        #expect(recurred.lastNightID == nights.second)
        let last = try #require(try nights.journal.lastRecordedFailureCause(cardID: nights.cardIDs[0]))
        #expect(last == RecordedFailureCause(summary: exitTwo.summary, causeHash: exitTwo.hash, recurrenceCount: 2))
    }

    @Test("Each cause and each Card keeps its own count")
    func causesAndCardsAreCountedApart() throws {
        let fixture = try JournalFixture()
        let nights = try Nights(try fixture.open(), issueIDs: ["ENG-1", "ENG-2"])

        _ = try nights.record(exitTwo, night: nights.first)
        #expect(try nights.record(signaled, night: nights.second).recurrenceCount == 1)
        #expect(try nights.record(exitTwo, card: 1, night: nights.second).recurrenceCount == 1)
        #expect(try nights.journal.failureCauses(cardID: nights.cardIDs[0]).count == 2)
    }

    @Test("The same hash in two Projects is counted once in each Journal: nothing joins the two counts")
    func projectsAreNeverCorrelated() throws {
        let fixtureA = try JournalFixture(project: "alpha")
        let fixtureB = try JournalFixture(project: "beta")
        let alpha = try Nights(try fixtureA.open())
        let beta = try Nights(try fixtureB.open())

        _ = try alpha.record(exitTwo, night: alpha.first)
        #expect(try alpha.record(exitTwo, night: alpha.second).hasRecurred)
        // Beta met the very same cause for the first time: alpha's two Nights are invisible to it.
        let inBeta = try beta.record(exitTwo, night: beta.first)
        #expect(inBeta.recurrenceCount == 1)
        #expect(!inBeta.hasRecurred)
    }

    @Test("Recording appends FailureCauseRecorded with the count, so a recurrence can be told from a first occurrence")
    func recordingAppendsTheEvent() throws {
        let fixture = try JournalFixture()
        let nights = try Nights(try fixture.open())

        _ = try nights.record(exitTwo, night: nights.first)
        _ = try nights.record(exitTwo, night: nights.second)

        let counts = try nights.journal.events(ofType: .failureCauseRecorded).compactMap {
            if case .failureCauseRecorded(_, "ENG-1", _, exitTwo.hash, let count) = $0.event { count } else { nil }
        }
        #expect(counts == [1, 2])
    }

    @Test("A run that lost the Act Lease records nothing")
    func aLostLeaseRecordsNothing() throws {
        let fixture = try JournalFixture()
        let nights = try Nights(try fixture.open())

        #expect(throws: JournalError.self) {
            try nights.journal.recordFailureCause(
                cardID: nights.cardIDs[0], cause: exitTwo, nightID: nights.first, runID: RunID(), now: epoch
            )
        }
        #expect(try nights.journal.failureCauses(cardID: nights.cardIDs[0]).isEmpty)
    }
}
