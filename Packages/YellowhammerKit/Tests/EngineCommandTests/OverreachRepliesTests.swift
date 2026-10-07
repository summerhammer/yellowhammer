import Domain
@testable import Engine
import Foundation
import Journal
import Testing

@Test("Linear overreach comments are recorded and acknowledged without answering, banking or changing the clock",
      arguments: [false, true])
func overreachRepliesAreRecordedOnly(landed: Bool) async throws {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
    let questionComment = try #require(world.questionCommentBoardID)
    _ = try journal.transitionCard(
        cardID: world.cardID, to: .waitingOnYou, waitingReason: .overreach, runID: world.runID,
        act: .build, nightID: world.night.id
    )
    try recordReplyOverlaps(world)
    let night = try world.openNight(NightStart(rawValue: "2026-09-21")!)
    _ = try journal.advanceCardUnansweredClocks(
        cycleIDs: [world.cycleID], nightID: night.id, unansweredNightsMax: 3, act: .build, runID: world.runID
    )
    if landed { try world.markCycleLanded() }
    let before = try world.card()
    let comments = [
        comment("overreach-top", on: "BACK-1", author: humanAuthor, createdAt: 3_600),
        comment("overreach-thread", on: "BACK-1", author: humanAuthor,
                parent: questionComment.rawValue, createdAt: 3_700)
    ]
    let reading = FakeReadingBoard([page(comments: comments), page(comments: comments)])
    for _ in 0..<2 {
        guard case .read(let report) = try await world.deltaRead(night: night, reading: reading).perform() else {
            Issue.record("expected Delta Read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.overreach, .overreach])
        #expect(report.waitingOnYouReplies.allSatisfy { $0.questionID == nil })
        try await WaitingOnYouReplies.apply(
            context: world.context(night: night, reading: reading), unansweredNightsMax: 3
        )
    }
    #expect(try world.card() == before)
    #expect(try journal.bankedCardReplies(cardID: world.cardID).isEmpty)
    #expect(try journal.cardReplies(questionID: #require(world.questionID), disposition: .answer).isEmpty)
    #expect(try journal.unappliedCardReplies().isEmpty)
    #expect(try journal.events(ofType: .waitingOnYouReplyRecorded).count == 2)
    let acks = await world.boards.writing.comments.filter { $0.body.hasPrefix("**Nothing changed;") }
    #expect(acks.count == 2)
    for ack in acks {
        #expect(ack.body.hasPrefix("**Nothing changed; 2 nights remain on the clock.**"))
        #expect(ack.body.contains("Secrets/one") && ack.body.contains("Secrets/two"))
        #expect(!ack.body.contains("Old/"))
        #expect(ack.body.contains("`Scope`") && ack.body.contains("Protected Paths configuration"))
    }
}

private func recordReplyOverlaps(_ world: ReplyWorld) throws {
    let journal = world.journal
    let old = world.clock.read().addingTimeInterval(-60)
    try journal.append(.protectedPathRefused(
        cardID: world.cardID, issueID: "BACK-1", repository: "backend",
        declaredPath: "Old/", protectedPath: "Old/secret"
    ), runID: world.runID, nightID: world.night.id, now: old)
    for path in ["Secrets/one", "Secrets/two"] {
        try journal.append(.protectedPathRefused(
            cardID: world.cardID, issueID: "BACK-1", repository: "backend",
            declaredPath: path, protectedPath: "Secrets/"
        ), runID: world.runID, nightID: world.night.id, now: world.clock.read())
    }
}
