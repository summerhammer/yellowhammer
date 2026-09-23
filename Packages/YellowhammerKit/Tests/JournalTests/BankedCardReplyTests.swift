import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Banking a Card Reply (roadmap P11.3; spec: board-projection/read-board-changes-by-delta, OQ37): once
// the Feature that put a Card in Waiting on You has landed, an answer is banked rather than dispatched
// — stamped with each touched Repo's mainline commit at banking time, and carried forward for
// opportunistic Adoption by a successor Feature.

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
private let nightStart = NightStart(rawValue: "2026-09-23")!
private let route = Route(cli: "claude", model: "opus", effort: "high")!

/// A Journal with one Card, a held Act Lease, one open Night, one Attempt, one recorded question, and
/// one recorded reply of the given disposition.
private struct BankWorld {
    let journal: JournalStore
    let runID = RunID()
    let cardID: Int64
    let cycleID: Int64
    let nightID: Int64
    let replyID: Int64

    init(_ journal: JournalStore, disposition: CardReplyDisposition = .answer) throws {
        self.journal = journal
        (cardID, cycleID) = try BankWorld.insertFixtureCard(journal)
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        nightID = try journal.openNight(nightStart: nightStart, mode: .rehearsal, act: .build, runID: runID, now: epoch)
            .night.id
        let attemptID = try journal.recordAttempt(
            cardID: cardID, route: route, runID: runID, act: .build, nightID: nightID, now: epoch
        ).id
        let questionID: Int64? = disposition == .answer || disposition == .remark
            ? try journal.recordCardQuestion(
                cardID: cardID, attemptID: attemptID, question: "Which endpoint should this call?",
                commentClientID: "CLIENT-1", nightID: nightID, act: .build, runID: runID, now: epoch
            ).id
            : nil
        let draft = CardReplyDraft(
            cardID: cardID, issueID: "ENG-1", questionID: questionID, commentID: "comment-1",
            body: "the answer", authorName: "Max", disposition: disposition, commentedAt: epoch
        )
        replyID = try journal.recordCardReply(draft, nightID: nightID, act: .build, runID: runID, now: epoch).id
    }

    /// Opens one more Night, re-claiming the Act Lease first.
    func openNight(_ start: NightStart, now: Date) throws -> Int64 {
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        return try journal.openNight(nightStart: start, mode: .rehearsal, act: .build, runID: runID, now: now).night.id
    }

    /// Records one more reply (answer) on the same Card, for ordering tests.
    func recordAnotherReply(commentID: String, nightID: Int64) throws -> Int64 {
        let draft = CardReplyDraft(
            cardID: cardID, issueID: "ENG-1", questionID: nil, commentID: commentID,
            body: "another answer", authorName: "Max", disposition: .answer, commentedAt: epoch
        )
        return try journal.recordCardReply(draft, nightID: nightID, act: .build, runID: runID, now: epoch).id
    }

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
                    cycleID, "ENG-1", "backend", "impl", 1, CardState.waitingOnYou.rawValue, 0,
                    JournalStore.timestamp(epoch)
                ]
            )
            return (db.lastInsertedRowID, cycleID)
        }
    }
}

@Suite("Banking a Card Reply (P11.3)")
struct BankedCardReplyTests {
    @Test("Banking sets banked_at, inserts one stamp per repository, and appends WaitingOnYouReplyBanked")
    func banksSetsBankedAtAndStamps() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        let stamps = [MainlineStamp(repository: "backend", commit: "abc123")]
        let banked = try world.journal.bankCardReply(
            id: world.replyID, stamps: stamps, nightID: world.nightID, act: .author, runID: world.runID, now: epoch
        )

        #expect(banked.bankedAt == epoch)
        #expect(banked.nightID == world.nightID)
        #expect(banked.stamps == stamps)

        let events = try world.journal.events(ofType: .waitingOnYouReplyBanked)
        #expect(events.count == 1)
        guard case .waitingOnYouReplyBanked(let cardID, let issueID, let commentID) = events[0].event else {
            Issue.record("expected waitingOnYouReplyBanked")
            return
        }
        #expect(cardID == world.cardID)
        #expect(issueID == "ENG-1")
        #expect(commentID == "comment-1")
    }

    @Test("Banking twice is idempotent: same stamps, one event, even when called with different stamps")
    func bankingIsIdempotent() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        let firstStamps = [MainlineStamp(repository: "backend", commit: "abc123")]
        let first = try world.journal.bankCardReply(
            id: world.replyID, stamps: firstStamps, nightID: world.nightID, runID: world.runID, now: epoch
        )

        let differentStamps = [MainlineStamp(repository: "backend", commit: "different-commit")]
        let second = try world.journal.bankCardReply(
            id: world.replyID, stamps: differentStamps, nightID: world.nightID, runID: world.runID,
            now: epoch.addingTimeInterval(10)
        )

        #expect(second.bankedAt == first.bankedAt)
        #expect(second.stamps == first.stamps)
        #expect(try world.journal.events(ofType: .waitingOnYouReplyBanked).count == 1)
    }

    @Test("An unresolved mainline stamp (nil commit) is never stored: no banked_reply_mainline row")
    func unresolvedStampIsNeverStored() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        let stamps = [MainlineStamp(repository: "backend", commit: nil)]
        let banked = try world.journal.bankCardReply(
            id: world.replyID, stamps: stamps, nightID: world.nightID, runID: world.runID, now: epoch
        )

        #expect(banked.stamps.isEmpty)
    }

    @Test("Banking a remark throws cardReplyNotAnswer")
    func bankingARemarkThrows() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open(), disposition: .remark)

        #expect(throws: JournalError.cardReplyNotAnswer(id: world.replyID)) {
            try world.journal.bankCardReply(
                id: world.replyID, stamps: [], nightID: world.nightID, runID: world.runID, now: epoch
            )
        }
    }

    @Test("bankedCardReplies orders by id ASC, across two banked replies")
    func bankedCardRepliesOrdersById() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-24")!, now: epoch.addingTimeInterval(86_400))
        let secondReplyID = try world.recordAnotherReply(commentID: "comment-2", nightID: night2)

        _ = try world.journal.bankCardReply(
            id: secondReplyID, stamps: [MainlineStamp(repository: "backend", commit: "second")],
            nightID: night2, runID: world.runID, now: epoch.addingTimeInterval(86_400)
        )
        _ = try world.journal.bankCardReply(
            id: world.replyID, stamps: [MainlineStamp(repository: "backend", commit: "first")],
            nightID: world.nightID, runID: world.runID, now: epoch
        )

        let banked = try world.journal.bankedCardReplies(cardID: world.cardID)
        #expect(banked.map(\.reply.id) == [world.replyID, secondReplyID])
        #expect(banked.map { $0.stamps.first?.commit } == ["first", "second"])
    }

    @Test("cardIDsWithBankedReplies names only Cards with at least one banked reply, in the given Cycle")
    func cardIDsWithBankedRepliesNamesOnlyBankedCards() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        #expect(try world.journal.cardIDsWithBankedReplies(cycleID: world.cycleID).isEmpty)

        _ = try world.journal.bankCardReply(
            id: world.replyID, stamps: [], nightID: world.nightID, runID: world.runID, now: epoch
        )

        #expect(try world.journal.cardIDsWithBankedReplies(cycleID: world.cycleID) == [world.cardID])
    }

    @Test("hasWaitingOnYouCardInLandedCycle is true only once the Cycle has landed")
    func hasWaitingOnYouCardInLandedCycleReflectsLandedState() throws {
        let fixture = try JournalFixture()
        let world = try BankWorld(try fixture.open())

        #expect(try world.journal.hasWaitingOnYouCardInLandedCycle() == false)

        try world.journal.markCycleLanded(cycleID: world.cycleID, runID: world.runID, now: epoch)

        #expect(try world.journal.hasWaitingOnYouCardInLandedCycle() == true)
    }
}
