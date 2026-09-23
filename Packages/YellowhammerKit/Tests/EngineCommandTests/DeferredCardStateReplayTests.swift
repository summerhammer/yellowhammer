import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// Issue #96: a Card state write a merge closure or a settle release deferred (rate limit,
// transient outage) is otherwise never retried, because the caller runs no Card and releases the Card
// Lease the instant the write is accepted. ``DeferredCardStateReplay`` is the standalone replay the
// author and land Acts run in their own write-back to pick it back up.

/// A board with the writable states ``BoardStateScope`` resolves, mirroring
/// `BoardStateProjectionTests.makeProjectionBoards()`.
private func makeReplayBoards() async throws -> NightCardTestBoards {
    let boards = try await makeBoards()
    await boards.provisioning.seed(state: "In Progress", team: teamID, category: .started)
    await boards.provisioning.seed(state: "Blocked", team: teamID, category: .unstarted)
    await boards.provisioning.seed(state: "Waiting on You", team: teamID, category: .unstarted)
    return boards
}

private func replayContext(
    _ journal: JournalStore, board: NightCardTestBoards, runID: RunID = RunID()
) throws -> ActContext {
    let outbox = try outbox(journal, board: board.writing, runID: runID)
    let night = try journal.openNight(nightStart: nightCardNightStart, mode: .real, act: .build, runID: runID).night
    let actBoard = ActBoard(
        reading: FakeReadingBoard([]), writing: board.writing, provisioning: board.provisioning
    )
    return ActContext(
        act: .build, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night,
        outbox: outbox, board: actBoard
    )
}

@Suite("Deferred Card state replay")
struct DeferredCardStateReplayTests {
    @Test("Nothing unposted: no board call, no event")
    func nothingUnpostedIsZeroCost() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeReplayBoards()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        // A freshly authored Card is Todo, unposted at state_version 0 — filtered out, not "posted".
        _ = try insertFixtureCard(journal, issueID: "issue-1")
        let context = try replayContext(journal, board: boards)

        try await DeferredCardStateReplay.run(context: context)

        #expect(await boards.writing.updateCalls == 0)
        #expect(try journal.events(ofType: .boardStateReposted).isEmpty)
    }

    @Test("A Card at state_version 0 is never replayed, even though it is unposted")
    func stateVersionZeroIsFiltered() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeReplayBoards()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let context = try replayContext(journal, board: boards)

        #expect(try journal.cardsWithUnpostedState().map(\.id) == [cardID])

        try await DeferredCardStateReplay.run(context: context)

        #expect(await boards.writing.updateCalls == 0)
        #expect(try journal.events(ofType: .boardStateReposted).isEmpty)
        #expect(try journal.currentCardLease(cardID: cardID) == nil)
    }

    @Test("A deferred Card write is replayed: the board catches up and the event is appended")
    func deferredWriteIsReplayed() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeReplayBoards()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let context = try replayContext(journal, board: boards)

        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: context.runID, act: .build, nightID: nil, now: outboxEpoch
        )
        #expect(try journal.card(id: cardID).boardStateVersion == nil)

        try await DeferredCardStateReplay.run(context: context)

        #expect(await boards.writing.updateCalls == 1)
        #expect(try journal.card(id: cardID).boardStateVersion == 1)
        #expect(try journal.currentCardLease(cardID: cardID) == nil)
        let events = try journal.events(ofType: .boardStateReposted)
        #expect(events.count == 1)
        guard case .boardStateReposted(let cards) = try #require(events.first).event else {
            Issue.record("expected boardStateReposted")
            return
        }
        #expect(cards == 1)
    }

    @Test("Never takes over another run's expired Card Lease: the row and the board are untouched")
    func neverReclaimsAnExpiredLease() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeReplayBoards()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let context = try replayContext(journal, board: boards)
        let deadRunID = RunID()

        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: context.runID, act: .build, nightID: nil, now: outboxEpoch
        )
        // A dead run's lease, long expired — `ExpiredLeaseSweep` has not run and never will for this Act.
        _ = try journal.claimCardLease(cardID: cardID, runID: deadRunID, now: outboxEpoch)

        try await DeferredCardStateReplay.run(context: context)

        #expect(await boards.writing.updateCalls == 0)
        #expect(try journal.card(id: cardID).boardStateVersion == nil)
        #expect(try journal.currentCardLease(cardID: cardID)?.runID == deadRunID)
    }

    @Test("Scope resolution refused for the rate budget: appends rateBudgetExhausted, never throws")
    func scopeResolutionRateLimited() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeReplayBoards()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let context = try replayContext(journal, board: boards)

        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: context.runID, act: .build, nightID: nil, now: outboxEpoch
        )
        await boards.provisioning.refuseNext(.rateLimited(retryAfter: nil, budget: nil))

        try await DeferredCardStateReplay.run(context: context)

        #expect(await boards.writing.updateCalls == 0)
        let events = try journal.events(ofType: .rateBudgetExhausted)
        #expect(events.count == 1)
    }

    @Test("No Outbox or Board bound: nothing is written")
    func noOutboxOrBoardWritesNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let night = try journal.openNight(
            nightStart: nightCardNightStart, mode: .real, act: .author, runID: runID
        ).night
        let context = ActContext(
            act: .author, mode: .real, trigger: .scheduled, runID: runID, journal: journal, night: night
        )

        try await DeferredCardStateReplay.run(context: context)

        #expect(try journal.events(ofType: .boardStateReposted).isEmpty)
        #expect(try journal.events(ofType: .rateBudgetExhausted).isEmpty)
    }
}
