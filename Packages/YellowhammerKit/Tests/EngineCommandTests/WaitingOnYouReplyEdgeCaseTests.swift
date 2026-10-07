import Domain
@testable import Engine
import Foundation
import GRDB
import Journal
import Testing

// Edge cases of answer detection and resumption (roadmap P11.2), split out of
// WaitingOnYouAnswerTests.swift to keep that file under the length limit: comments that record
// nothing at all, and crash-safety across a replayed Delta Read and a re-run apply step.

@Suite("Waiting on You reply edge cases (P11.2)")
struct WaitingOnYouReplyEdgeCaseTests {
    @Test("Own comments, Cards not Waiting on You, and a Card Shelved in the same read record nothing")
    func nothingIsRecordedForThreeKindsOfNoise() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        let boardID = try #require(world.questionCommentBoardID)

        // A second Card, never Waiting on You.
        let cycleID = try journal.read { db -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT cycle_id FROM card WHERE id = ?", arguments: [world.cardID])!
        }
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo)

        // A third Card, Waiting on You / question, but Shelved in this very same Delta Read.
        let thirdCardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-3", repository: "backend", state: .todo
        )
        _ = try journal.transitionCard(
            cardID: thirdCardID, to: .waitingOnYou, waitingReason: .question, runID: world.runID, act: .build,
            nightID: world.night.id, now: world.clock.read()
        )

        // Yellowhammer's own comment on the question Card: never even reaches `humanComments`.
        let ownComment = comment(
            "own-1", on: "BACK-1", author: BoardCommentAuthor(id: nil, name: "Yellowhammer", isYellowhammer: true),
            parent: boardID.rawValue, createdAt: 3_600
        )
        // A human comment on the Card that is not Waiting on You.
        let onOrdinaryCard = comment("comment-2", on: "BACK-2", author: humanAuthor, createdAt: 3_600)
        // A human comment on the Card that this same read also finds Shelved.
        let onShelvedCard = comment(
            "comment-3", on: "BACK-3", author: humanAuthor, parent: nil, createdAt: 3_600
        )
        let shelvedObject = object("BACK-3", state: stateShelved)

        let reading = FakeReadingBoard([
            page(objects: [shelvedObject], comments: [ownComment, onOrdinaryCard, onShelvedCard])
        ])
        guard case .read(let report) = try await world.deltaRead(night: world.night, reading: reading).perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.waitingOnYouReplies.isEmpty)
        #expect(report.ownComments == 1)
        #expect(try journal.unappliedCardReplies().isEmpty)
        #expect(try journal.events(ofType: .waitingOnYouReplyRecorded).isEmpty)
        #expect(try journal.card(id: thirdCardID).state == .shelved, "the Shelve itself still applies")
    }

    @Test("A replayed Delta Read and a re-run apply step are idempotent; an unapplied reply is applied next Act")
    func replayIsIdempotentAndDeferredApplyCompletesLater() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        // Scripted twice: simulates the same comment read again because an earlier Act crashed before
        // the sync point moved.
        let reading = FakeReadingBoard([page(comments: [replyComment]), page(comments: [replyComment])])

        guard case .read(let firstReport) = try await world.deltaRead(night: world.night, reading: reading).perform()
        else {
            Issue.record("expected a read")
            return
        }
        #expect(firstReport.waitingOnYouReplies.count == 1)
        #expect(try journal.unappliedCardReplies().count == 1)
        // Not applied yet: simulates a crash between recording and the apply step.

        guard case .read(let secondReport) = try await world.deltaRead(night: world.night, reading: reading).perform()
        else {
            Issue.record("expected a read")
            return
        }
        #expect(secondReport.waitingOnYouReplies.count == 1, "the replay resolves to the same row")
        #expect(try journal.unappliedCardReplies().count == 1, "still exactly one row")
        #expect(try journal.events(ofType: .waitingOnYouReplyRecorded).count == 1, "no duplicate event")

        // The next build Act's apply step completes what the "crashed" Act left unapplied.
        let context = world.context(night: world.night, reading: reading)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        #expect(try world.card().state == .todo)
        #expect(try journal.unappliedCardReplies().isEmpty)
        let acksAfterFirstApply = await world.boards.writing.comments.filter {
            $0.body == WaitingOnYouAcknowledgement.answer()
        }
        #expect(acksAfterFirstApply.count == 1)

        // A re-run of the apply step (an Act that finds nothing left unapplied) posts no duplicate ack.
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)
        let acksAfterSecondApply = await world.boards.writing.comments.filter {
            $0.body == WaitingOnYouAcknowledgement.answer()
        }
        #expect(acksAfterSecondApply.count == 1, "no duplicate Outbox entry, no duplicate ack")
    }
}
