import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// Banking a Card Reply after landing (roadmap P11.3; spec: board-projection/read-board-changes-by-
// delta, OQ37): once the Feature that put a Card in Waiting on You has landed, lanes do not reopen, so
// an answer is banked — recorded, stamped with each touched Repo's mainline commit, and left in
// Waiting on You for opportunistic Adoption — rather than dispatched.

private let bankedMainlineCommit = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let secondBankedMainlineCommit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func backendMainlines(commit: String) -> ResolvedMainlines {
    ResolvedMainlines(workingRepos: [
        "backend": ResolvedMainline(
            repository: "backend", defaultBranch: "main", ref: "refs/heads/main", commit: commit
        )
    ])
}

@Suite("Banking a Waiting on You reply after landing (P11.3)")
struct WaitingOnYouBankedReplyTests {
    @Test("A first banked reply: the Card stays Waiting on You, is stamped, and is not repeat-worded")
    func firstBankedReply() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        guard case .read(let report) = try await world.deltaRead(night: world.night, reading: reading).perform()
        else {
            Issue.record("expected a read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.answer])

        let context = world.context(
            night: world.night, reading: reading, mainlines: backendMainlines(commit: bankedMainlineCommit)
        )
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        let card = try world.card()
        #expect(card.state == .waitingOnYou, "nothing runs; the Card stays where it is")
        #expect(card.waitingReason == .question)
        switch try journal.claimCardLease(cardID: world.cardID, runID: RunID()) {
        case .claimed: break
        default: Issue.record("banking must never leave the Card Lease held")
        }

        let banked = try journal.bankedCardReplies(cardID: world.cardID)
        #expect(banked.count == 1)
        #expect(banked[0].nightID == world.night.id)
        #expect(banked[0].stamps == [MainlineStamp(repository: "backend", commit: bankedMainlineCommit)])

        let expectedAck = WaitingOnYouAcknowledgement.banked(stamps: banked[0].stamps, isRepeat: false)
        let acks = await world.boards.writing.comments.filter { $0.id != boardID }
        #expect(acks.count == 1)
        #expect(acks[0].body == expectedAck)

        #expect(try journal.unappliedCardReplies().isEmpty)
        #expect(try journal.events(ofType: .waitingOnYouReplyBanked).count == 1)
    }

    @Test("A second banked reply on a later Night is appended, worded as a repeat, its own Night and stamp")
    func secondBankedReplyIsARepeat() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let firstReply = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let firstReading = FakeReadingBoard([page(comments: [firstReply])])
        _ = try await world.deltaRead(night: world.night, reading: firstReading).perform()
        let firstContext = world.context(
            night: world.night, reading: firstReading, mainlines: backendMainlines(commit: bankedMainlineCommit)
        )
        try await WaitingOnYouReplies.apply(context: firstContext, unansweredNightsMax: 3)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!)
        let secondReply = comment(
            "reply-2", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue, createdAt: 3_600
        )
        let secondReading = FakeReadingBoard([page(comments: [secondReply])])
        _ = try await world.deltaRead(night: night2, reading: secondReading).perform()
        let secondContext = world.context(
            night: night2, reading: secondReading, mainlines: backendMainlines(commit: secondBankedMainlineCommit)
        )
        try await WaitingOnYouReplies.apply(context: secondContext, unansweredNightsMax: 3)

        let banked = try journal.bankedCardReplies(cardID: world.cardID)
        #expect(banked.count == 2)
        #expect(banked.map { $0.reply.nightID } == [world.night.id, night2.id])
        #expect(banked.map { $0.stamps.first?.commit } == [bankedMainlineCommit, secondBankedMainlineCommit])

        let firstAckBody = WaitingOnYouAcknowledgement.banked(stamps: banked[0].stamps, isRepeat: false)
        let secondAckBody = WaitingOnYouAcknowledgement.banked(stamps: banked[1].stamps, isRepeat: true)
        let comments = await world.boards.writing.comments
        #expect(comments.filter { $0.body == firstAckBody }.count == 1, "the first ack is not reposted")
        #expect(comments.filter { $0.body == secondAckBody }.count == 1)
    }

    @Test("Applying twice posts no duplicate ack and does not re-stamp")
    func applyingTwiceIsIdempotent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        _ = try await world.deltaRead(night: world.night, reading: reading).perform()

        let context = world.context(
            night: world.night, reading: reading, mainlines: backendMainlines(commit: bankedMainlineCommit)
        )
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        #expect(try journal.events(ofType: .waitingOnYouReplyBanked).count == 1)
        let banked = try journal.bankedCardReplies(cardID: world.cardID)
        #expect(banked.count == 1)
        #expect(banked[0].stamps == [MainlineStamp(repository: "backend", commit: bankedMainlineCommit)])
        let acks = await world.boards.writing.comments.filter { $0.id != boardID }
        #expect(acks.count == 1)
    }

    @Test("An unresolved mainline banks no stamp row and renders 'mainline unresolved'")
    func unresolvedMainlineBanksWithNoStampRow() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        _ = try await world.deltaRead(night: world.night, reading: reading).perform()

        let context = world.context(night: world.night, reading: reading, mainlines: ResolvedMainlines())
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        let banked = try journal.bankedCardReplies(cardID: world.cardID)
        #expect(banked[0].stamps.isEmpty, "no banked_reply_mainline row for an unresolved repository")

        let ack = try #require(await world.boards.writing.comments.first { $0.id != boardID })
        #expect(ack.body.contains("mainline unresolved on `backend`"))
    }

    @Test("A remark on a landed Card is acknowledged with (b) and never banked")
    func remarkOnLandedCardIsNotBanked() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()

        let remark = comment("remark-1", on: "BACK-1", author: humanAuthor, parent: nil, createdAt: 3_600)
        let reading = FakeReadingBoard([page(comments: [remark])])
        _ = try await world.deltaRead(night: world.night, reading: reading).perform()

        let context = world.context(night: world.night, reading: reading)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        #expect(try journal.bankedCardReplies(cardID: world.cardID).isEmpty)
        #expect(try journal.card(id: world.cardID).state == .waitingOnYou)
        let expectedBody = WaitingOnYouAcknowledgement.remark(question: replyQuestionText, nightsRemaining: 3)
        let ack = try #require(await world.boards.writing.comments.first { $0.body == expectedBody })
        #expect(ack.issue.rawValue == "BACK-1")
    }

    @Test("AuthorAct's post-landing step banks a reply when the Cycle has landed")
    func authorActBanksAfterLanding() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        let context = world.context(
            night: world.night, reading: reading, act: .author,
            mainlines: backendMainlines(commit: bankedMainlineCommit)
        )

        try await PostLandingReplies.run(context: context, unansweredNightsMax: 3)

        let calls = await reading.calls
        #expect(calls.count == 1, "the author Act performs its own Delta Read")
        #expect(try journal.bankedCardReplies(cardID: world.cardID).count == 1)
    }

    @Test("AuthorAct's post-landing step performs no Delta Read while an unlanded Cycle is in flight")
    func noReadWhileUnlandedCycleInFlight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        // makeReplyWorld's own Feature/Cycle is in flight and unlanded (markCycleLanded is never
        // called), which alone must be enough to hold this step back.
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)

        let reading = FakeReadingBoard([])
        let context = world.context(night: world.night, reading: reading, act: .author)

        try await PostLandingReplies.run(context: context, unansweredNightsMax: 3)

        let calls = await reading.calls
        #expect(calls.isEmpty, "an unlanded in-flight Cycle must never lose the build Act's own Delta Read")
    }

    @Test("AuthorAct's post-landing step performs no Delta Read when nothing is Waiting on You in a landed Cycle")
    func noReadWhenNothingToBank() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        // Resolve the Card out of Waiting on You before landing, so nothing is left to bank.
        _ = try journal.transitionCard(
            cardID: world.cardID, to: .todo, waitingReason: nil, runID: world.runID, act: .build,
            nightID: world.night.id, now: world.clock.read()
        )
        try world.markCycleLanded()

        let reading = FakeReadingBoard([])
        let context = world.context(night: world.night, reading: reading, act: .author)

        try await PostLandingReplies.run(context: context, unansweredNightsMax: 3)

        let calls = await reading.calls
        #expect(calls.isEmpty, "a Project with nothing to bank must spend no request")
    }
}
