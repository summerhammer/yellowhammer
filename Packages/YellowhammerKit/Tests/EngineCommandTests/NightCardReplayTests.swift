import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// shift-scheduling/open-and-close-the-night-card (P5.7): Outbox idempotency across a crashed and
// resumed Act, and Project isolation, split out of NightCardTests.swift to keep that suite under the
// type body length limit.

@Suite("Night Card idempotency and Project isolation")
struct NightCardReplayTests {
    @Test("A killed-and-resumed Act leaves exactly one Night Card")
    func killedAndResumedLeavesOne() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing

        let run1 = RunID()
        _ = try journal.claimActLease(act: .author, runID: run1, mode: .real)
        let night = try journal.openNight(nightStart: nightCardNightStart, mode: .real, act: .author, runID: run1).night

        let crashingOutbox = Outbox(
            journal: journal, board: writing, runID: run1, act: .author, nightID: night.id,
            interrupt: { _ in throw SimulatedCrash() }
        )
        let crashingMaintenance = NightCardMaintenance(
            journal: journal, outbox: crashingOutbox, provisioning: provisioning
        )
        await #expect(throws: SimulatedCrash.self) {
            try await crashingMaintenance.open(night: night)
        }

        let afterCrash = try #require(try journal.night(id: night.id))
        #expect(afterCrash.nightCardIssueID == nil)
        try journal.releaseActLease(runID: run1)

        let run2 = RunID()
        _ = try journal.claimActLease(act: .author, runID: run2, mode: .real)
        let resumedOutbox = Outbox(journal: journal, board: writing, runID: run2, act: .author, nightID: night.id)
        let resumedMaintenance = NightCardMaintenance(
            journal: journal, outbox: resumedOutbox, provisioning: provisioning
        )
        let opening = try await resumedMaintenance.open(night: afterCrash)

        guard case .opened(_, let replayed) = opening else {
            Issue.record("Expected .opened, got \(opening)")
            return
        }
        #expect(replayed)
        #expect(await writing.liveIssues.count == 1)
        #expect(await writing.createIssueCalls == 2)
    }

    @Test("Two Projects get two Night Cards")
    func twoProjectsGetTwoNightCards() async throws {
        let fixtureAlpha = try NightCardJournalFixture(project: "alpha")
        let fixtureBeta = try NightCardJournalFixture(project: "beta")
        let journalAlpha = try fixtureAlpha.open()
        let journalBeta = try fixtureBeta.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(writing: writing, provisioning: provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journalAlpha,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journalBeta,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()

        #expect(await writing.liveIssues.count == 2)

        let createKey = NightCardMaintenance.createKey(nightStart: nightCardNightStart)
        let outboxAlpha = Outbox(journal: journalAlpha, board: writing, runID: RunID())
        let outboxBeta = Outbox(journal: journalBeta, board: writing, runID: RunID())
        #expect(outboxAlpha.clientID(for: createKey) != outboxBeta.clientID(for: createKey))
    }
}
