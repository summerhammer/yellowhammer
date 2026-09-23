import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Card side of the unanswered-Nights clock's own arithmetic (roadmap P11.4; spec:
// bounds/bound-unanswered-nights), mirroring RefusalStoreTests.swift's coverage of the Refusal clock,
// but counted per Card and gated on a banked reply the way ``JournalStore/hasWaitingOnYouCardInLandedCycle()``
// already is. `unanswered_nights_max = 1` throughout, so a Card's second qualifying Night pushes it past
// the bound.

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
private let night1Start = NightStart(rawValue: "2026-09-20")!

/// A Journal with one Card in Waiting on You, entered on Night 1, a held Act Lease, ready to open
/// further Nights and advance the clock.
private struct ClockWorld {
    let journal: JournalStore
    let runID = RunID()
    let cardID: Int64
    let cycleID: Int64
    let night1ID: Int64

    init(_ journal: JournalStore, waitingReason: WaitingReason = .question) throws {
        self.journal = journal
        (cardID, cycleID) = try ClockWorld.insertFixtureCard(journal)
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch)
        else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        night1ID = try journal.openNight(
            nightStart: night1Start, mode: .rehearsal, act: .build, runID: runID, now: epoch
        ).night.id
        _ = try journal.transitionCard(
            cardID: cardID, to: .waitingOnYou, waitingReason: waitingReason, runID: runID, act: .build,
            nightID: night1ID, now: epoch
        )
    }

    /// Opens one more Night, re-claiming the Act Lease first.
    func openNight(_ start: NightStart, now: Date) throws -> Int64 {
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        return try journal.openNight(nightStart: start, mode: .rehearsal, act: .build, runID: runID, now: now).night.id
    }

    func card() throws -> CardRecord { try journal.card(id: cardID) }

    static func insertFixtureCard(_ journal: JournalStore) throws -> (cardID: Int64, cycleID: Int64) {
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
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, "ENG-1", "backend", "impl", 1, CardState.todo.rawValue, 0, JournalStore.timestamp(epoch)
                ]
            )
            return (db.lastInsertedRowID, cycleID)
        }
    }
}

@Suite("The unanswered-Nights clock's arithmetic (P11.4)")
struct CardUnansweredClockTests {
    @Test("The opening Night never counts; the first qualifying Night counts 1 and stays under a bound of 1")
    func openingNightNeverCounts() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open())

        // Advancing on the opening Night itself must add nothing: `transitionCard` already recorded it
        // as counted.
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: world.night1ID, unansweredNightsMax: 1, act: .build,
            runID: world.runID
        )
        #expect(try world.card().unansweredNights == 0)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        let fired = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(fired.isEmpty, "a count of 1 does not exceed a bound of 1")
        #expect(try world.card().unansweredNights == 1)
        #expect(try world.card().state == .waitingOnYou)
    }

    @Test("A second qualifying Night exceeds the bound: the Card is named, with the `unanswered` reason")
    func secondNightExceedsBoundOnQuestionRoute() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open(), waitingReason: .question)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )

        let night3 = try world.openNight(
            NightStart(rawValue: "2026-09-22")!, now: epoch.addingTimeInterval(2 * 86_400)
        )
        let fired = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night3, unansweredNightsMax: 1, act: .build, runID: world.runID
        )

        #expect(fired.map(\.id) == [world.cardID])
        #expect(try world.card().unansweredNights == 2)
        #expect(try world.card().state == .waitingOnYou, "the bound firing only records; blocking is a later step")

        let overdue = try world.journal.cardsPastUnansweredBound(cycleIDs: [world.cycleID], unansweredNightsMax: 1)
        #expect(overdue.map(\.id) == [world.cardID])

        let events = try world.journal.events(ofType: .cardUnansweredBoundFired)
        #expect(events.count == 1)
        guard case .cardUnansweredBoundFired(let cardID, let issueID, let unansweredNights, let bound, let blockReason)
            = events[0].event
        else {
            Issue.record("expected cardUnansweredBoundFired")
            return
        }
        #expect(cardID == world.cardID)
        #expect(issueID == "ENG-1")
        #expect(unansweredNights == 2)
        #expect(bound == 1)
        #expect(blockReason == "unanswered")
    }

    @Test("On the divergence route the bound fires with `undecided`, never `unanswered`")
    func divergenceRouteFiresUndecided() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open(), waitingReason: .divergence)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        let night3 = try world.openNight(
            NightStart(rawValue: "2026-09-22")!, now: epoch.addingTimeInterval(2 * 86_400)
        )
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night3, unansweredNightsMax: 1, act: .build, runID: world.runID
        )

        let events = try world.journal.events(ofType: .cardUnansweredBoundFired)
        guard case .cardUnansweredBoundFired(_, _, _, _, let blockReason) = events[0].event else {
            Issue.record("expected cardUnansweredBoundFired")
            return
        }
        #expect(blockReason == "undecided")
    }

    @Test("Advancing twice for the same Night (author and build Acts) counts once")
    func idempotentWithinANight() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open())

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .author, runID: world.runID
        )
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )

        #expect(try world.card().unansweredNights == 1, "a second Act of the same Night adds nothing")
    }

    @Test("A stopped Project's next recorded Night advances the clock by exactly one, not by calendar days")
    func stoppedProjectAdvancesByOneNightOnly() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open())

        // A week passes with no Acts in between; the next Night this Project actually runs is still
        // just one more Night on the clock.
        let nightAWeekLater = try world.openNight(
            NightStart(rawValue: "2026-09-27")!, now: epoch.addingTimeInterval(7 * 86_400)
        )
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: nightAWeekLater, unansweredNightsMax: 1, act: .build,
            runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1)

        // With no further Act, nothing changes.
        #expect(try world.card().unansweredNights == 1)
    }

    @Test("A Card with a banked reply does not advance, and stays Waiting on You")
    func bankedReplyHaltsTheClock() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open())

        let draft = CardReplyDraft(
            cardID: world.cardID, issueID: "ENG-1", questionID: nil, commentID: "comment-1", body: "the answer",
            authorName: "Max", disposition: .answer, commentedAt: epoch
        )
        let reply = try world.journal.recordCardReply(
            draft, nightID: world.night1ID, act: .build, runID: world.runID, now: epoch
        )
        _ = try world.journal.bankCardReply(
            id: reply.id, stamps: [], nightID: world.night1ID, act: .build, runID: world.runID, now: epoch
        )

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        let fired = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )

        #expect(fired.isEmpty)
        #expect(try world.card().unansweredNights == 0)
        #expect(try world.card().state == .waitingOnYou)
    }

    @Test("Cancelled suspends the clock: unchanged across Nights, resumes (not resets) on reopening")
    func cancelledSuspendsTheClock() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open())

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1)

        _ = try world.journal.markCardCancelled(
            cardID: world.cardID, runID: world.runID, act: .build, nightID: night2,
            now: epoch.addingTimeInterval(86_400)
        )

        let night3 = try world.openNight(
            NightStart(rawValue: "2026-09-22")!, now: epoch.addingTimeInterval(2 * 86_400)
        )
        let night4 = try world.openNight(
            NightStart(rawValue: "2026-09-23")!, now: epoch.addingTimeInterval(3 * 86_400)
        )
        // Cancelled Cards are not Waiting on You, so the clock's own query never selects them.
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night3, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night4, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1, "unchanged while Cancelled")

        _ = try world.journal.restoreCancelledCard(
            cardID: world.cardID, runID: world.runID, act: .build, nightID: night4,
            now: epoch.addingTimeInterval(3 * 86_400)
        )
        #expect(try world.card().unansweredNights == 1, "resumes from where it was, not reset")
        #expect(try world.card().state == .waitingOnYou)

        let night5 = try world.openNight(
            NightStart(rawValue: "2026-09-24")!, now: epoch.addingTimeInterval(4 * 86_400)
        )
        let fired = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night5, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(fired.map(\.id) == [world.cardID], "fires on the next Night after reopening")
    }

    @Test("Entering Waiting on You afresh with a different waiting reason resets the clock to zero")
    func freshEntryResetsTheClock() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open(), waitingReason: .question)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1)

        _ = try world.journal.transitionCard(
            cardID: world.cardID, to: .waitingOnYou, waitingReason: .divergence, runID: world.runID, act: .build,
            nightID: night2, now: epoch.addingTimeInterval(86_400)
        )
        #expect(try world.card().unansweredNights == 0, "a different waiting reason restarts the clock")

        let night3 = try world.openNight(
            NightStart(rawValue: "2026-09-22")!, now: epoch.addingTimeInterval(2 * 86_400)
        )
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night3, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1, "night2, the fresh entry Night, did not count")
    }

    @Test("A repeat entry into Waiting on You for the same reason leaves the clock untouched")
    func sameReasonReentryLeavesClockUntouched() throws {
        let fixture = try JournalFixture()
        let world = try ClockWorld(try fixture.open(), waitingReason: .question)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!, now: epoch.addingTimeInterval(86_400))
        _ = try world.journal.advanceCardUnansweredClocks(
            cycleIDs: [world.cycleID], nightID: night2, unansweredNightsMax: 1, act: .build, runID: world.runID
        )
        #expect(try world.card().unansweredNights == 1)

        // A transition to the same state/reason is a no-op per `transitionCard`'s own contract.
        _ = try world.journal.transitionCard(
            cardID: world.cardID, to: .waitingOnYou, waitingReason: .question, runID: world.runID, act: .build,
            nightID: night2, now: epoch.addingTimeInterval(86_400)
        )
        #expect(try world.card().unansweredNights == 1)
    }
}
