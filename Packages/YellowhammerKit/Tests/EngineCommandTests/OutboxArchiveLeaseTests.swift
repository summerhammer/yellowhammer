import Domain
@testable import Engine
import Foundation
import Journal
import Testing

@Suite("Archive reads preserve mutation lease discipline")
struct OutboxArchiveLeaseTests {
    @Test("A Card lease lost during the last archive read defers the fenced rewrite")
    func cardLeaseLostDuringRead() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let cardID = try insertFixtureCard(journal, issueID: "card")
        _ = try journal.claimCardLease(cardID: cardID, runID: run)
        let issue = await boards.writing.seed(issue: "card", description: fencedDescription)
        await reading.onIssueRead(number: 2) { _ = try? journal.releaseCardLease(cardID: cardID, runID: run) }
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run)
        let delivery = try await outbox.post(OutboxWrite(
            key: "summary", write: .rewriteManagedBlock(issue: issue, rendered: "new"), cardID: cardID
        ))
        guard case .deferred(.cardLeaseNotHeld) = delivery.outcome else {
            Issue.record("expected the lost Card lease to defer delivery")
            return
        }
        #expect(await boards.writing.updateCalls == 0)
        #expect(delivery.entry.state == .pending)
    }

    @Test("An Act lease lost during the last archive read prevents the fenced mutation")
    func actLeaseLostDuringRead() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let issue = await boards.writing.seed(issue: "night", description: fencedDescription)
        await reading.onIssueRead(number: 2) { _ = try? journal.releaseActLease(runID: run) }
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run)
        await #expect(throws: OutboxError.staleRun(JournalError.actLeaseLost(runID: run, holder: nil))) {
            try await outbox.post(OutboxWrite(
                key: "summary", write: .rewriteManagedBlock(issue: issue, rendered: "new")
            ))
        }
        #expect(await boards.writing.updateCalls == 0)
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("Lease loss during post-write archive validation leaves delivery and hash unrecorded")
    func postReadLeaseLoss() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let issue = await boards.writing.seed(issue: "night", description: fencedDescription)
        await reading.onIssueRead(number: 3) { _ = try? journal.releaseActLease(runID: run) }
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run)
        await #expect(throws: OutboxError.staleRun(JournalError.actLeaseLost(runID: run, holder: nil))) {
            try await outbox.post(OutboxWrite(
                key: "summary", write: .rewriteManagedBlock(issue: issue, rendered: "new")
            ))
        }
        #expect(await boards.writing.updateCalls == 1)
        #expect(try journal.pendingOutboxEntries().count == 1)
        #expect(try journal.managedBlockLastPostedHash(issueID: issue.rawValue) == nil)
        #expect(try journal.events(ofType: .managedBlockWritten).isEmpty)
    }

    @Test("An intentional archive operation is delivered and is never treated as an archive race")
    func intentionalArchive() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real)
        let issue = await boards.writing.seed(issue: "feature", description: fencedDescription)
        let outbox = Outbox(journal: journal, board: boards.writing, reading: reading, runID: run)
        let delivery = try await outbox.post(OutboxWrite(key: "archive", write: .archiveIssue(issue: issue)))
        #expect(delivery.outcome == .applied(nil))
        #expect(delivery.entry.state == .applied)
        #expect(await boards.writing.issue(issue)?.archived == true)
    }

    @Test("A halt after a mid-Act archive posts on the current replacement")
    func haltedCommentUsesReplacement() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let reading = FakeReadingBoard([])
        try await reading.readThrough(boards)
        let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        await #expect(throws: SimulatedCrash.self) {
            try await EngineInvocation(
                act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
                trigger: .forced, board: board, work: { context in
                    let issue = BoardObjectID(rawValue: try #require(context.night.nightCardIssueID))
                    try await boards.writing.archiveIssue(issue)
                    throw SimulatedCrash()
                }
            ).run()
        }
        let current = try #require(try journal.currentNight())
        let comment = try #require(await boards.writing.comments.first)
        #expect(comment.issue.rawValue == current.nightCardIssueID)
        #expect(try journal.archivedNightCardIssueIDs(nightID: current.id).count == 1)
        #expect(await boards.writing.liveIssues.count == 1)
    }
}
