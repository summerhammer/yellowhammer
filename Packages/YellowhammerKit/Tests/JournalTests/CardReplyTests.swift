import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Card Reply table (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator,
// board-projection/read-board-changes-by-delta): a human comment on a Card in Waiting on You,
// classified and recorded before the board-side apply step runs.

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

/// A Journal with one Card, a held Act Lease, one open Night, one Attempt and one recorded question.
private struct ReplyWorld {
    let journal: JournalStore
    let runID = RunID()
    let cardID: Int64
    let nightID: Int64
    let attemptID: Int64
    let questionID: Int64

    init(_ journal: JournalStore) throws {
        self.journal = journal
        cardID = try ReplyWorld.insertFixtureCard(journal)
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        nightID = try journal.openNight(nightStart: nightStart, mode: .rehearsal, act: .build, runID: runID, now: epoch)
            .night.id
        attemptID = try journal.recordAttempt(
            cardID: cardID, route: route, runID: runID, act: .build, nightID: nightID, now: epoch
        ).id
        questionID = try journal.recordCardQuestion(
            cardID: cardID, attemptID: attemptID, question: "Which endpoint should this call?",
            commentClientID: "CLIENT-1", nightID: nightID, act: .build, runID: runID, now: epoch
        ).id
    }

    /// A draft against this world's Card and question, for a test to override just the fields it cares about.
    func draft(
        commentID: String, body: String = "a reply", disposition: CardReplyDisposition,
        commentedAt: Date = epoch, questionID: Int64? = nil
    ) -> CardReplyDraft {
        CardReplyDraft(
            cardID: cardID, issueID: "ENG-1", questionID: questionID ?? self.questionID, commentID: commentID,
            body: body, authorName: "Max", disposition: disposition, commentedAt: commentedAt
        )
    }

    /// Opens one more Night, so a test can assert `nightsElapsed` across a real gap. Re-claims the Act
    /// Lease first (refreshing its heartbeat, per ``JournalStore/claimCardLease``'s own rule) so a jump
    /// of `now` past the lease TTL does not itself throw `actLeaseLost`.
    func openNight(_ start: NightStart, now: Date) throws -> Int64 {
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        return try journal.openNight(nightStart: start, mode: .rehearsal, act: .build, runID: runID, now: now).night.id
    }

    private static func insertFixtureCard(_ journal: JournalStore) throws -> Int64 {
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
            return db.lastInsertedRowID
        }
    }
}

@Suite("Card Reply in the Journal (P11.2)")
struct CardReplyTests {
    @Test("Recording a reply round-trips its fields and appends WaitingOnYouReplyRecorded")
    func recordingRoundTrips() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())

        let record = try world.journal.recordCardReply(
            world.draft(commentID: "comment-1", body: "the answer", disposition: .answer),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        #expect(record.cardID == world.cardID)
        #expect(record.questionID == world.questionID)
        #expect(record.commentID == "comment-1")
        #expect(record.body == "the answer")
        #expect(record.authorName == "Max")
        #expect(record.disposition == .answer)
        #expect(record.commentedAt == epoch)
        #expect(record.nightID == world.nightID)
        #expect(record.appliedAt == nil)

        let events = try world.journal.events(ofType: .waitingOnYouReplyRecorded)
        #expect(events.count == 1)
        guard case .waitingOnYouReplyRecorded(let cardID, let issueID, let commentID, let disposition) =
            events[0].event
        else {
            Issue.record("expected waitingOnYouReplyRecorded")
            return
        }
        #expect(cardID == world.cardID)
        #expect(issueID == "ENG-1")
        #expect(commentID == "comment-1")
        #expect(disposition == "answer")
    }

    @Test("Recording the same comment id twice is idempotent: one row, one event")
    func recordingIsIdempotent() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())

        let first = try world.journal.recordCardReply(
            world.draft(commentID: "comment-1", body: "the answer", disposition: .answer),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )
        let replay = try world.journal.recordCardReply(
            world.draft(commentID: "comment-1", body: "the answer", disposition: .answer),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        #expect(first.id == replay.id)
        #expect(try world.journal.events(ofType: .waitingOnYouReplyRecorded).count == 1)
        #expect(try world.journal.unappliedCardReplies().count == 1)
    }

    @Test("unappliedCardReplies orders by id and excludes applied rows")
    func unappliedOrdersAndExcludesApplied() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())

        let first = try world.journal.recordCardReply(
            world.draft(commentID: "comment-1", body: "remark one", disposition: .remark),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )
        let second = try world.journal.recordCardReply(
            world.draft(
                commentID: "comment-2", body: "remark two", disposition: .remark,
                commentedAt: epoch.addingTimeInterval(10)
            ),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        #expect(try world.journal.unappliedCardReplies().map(\.id) == [first.id, second.id])

        let applied = try world.journal.markCardReplyApplied(id: first.id, now: epoch.addingTimeInterval(20))
        #expect(applied.appliedAt != nil)
        #expect(try world.journal.unappliedCardReplies().map(\.id) == [second.id])

        // Marking an already-applied reply applied again is a no-op that returns the same timestamp.
        let repeated = try world.journal.markCardReplyApplied(id: first.id, now: epoch.addingTimeInterval(999))
        #expect(repeated.appliedAt == applied.appliedAt)
    }

    @Test("cardReplies(questionID:disposition:) narrows to one disposition, oldest first")
    func cardRepliesNarrowsByDisposition() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())

        let answer1 = try world.journal.recordCardReply(
            world.draft(commentID: "comment-answer-1", body: "first answer", disposition: .answer),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )
        let answer2 = try world.journal.recordCardReply(
            world.draft(
                commentID: "comment-answer-2", body: "second answer", disposition: .answer,
                commentedAt: epoch.addingTimeInterval(5)
            ),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )
        _ = try world.journal.recordCardReply(
            world.draft(commentID: "comment-remark", body: "a remark", disposition: .remark),
            nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        let answers = try world.journal.cardReplies(questionID: world.questionID, disposition: .answer)
        #expect(answers.map(\.id) == [answer1.id, answer2.id])
        #expect(answers.map(\.body) == ["first answer", "second answer"])

        let all = try world.journal.cardReplies(questionID: world.questionID)
        #expect(all.count == 3)
    }

    @Test("nightsElapsed counts Night rows strictly after the first through the second, inclusive")
    func nightsElapsedCountsBetweenTwoNights() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())

        // world.nightID is the question's own Night; it never counts.
        #expect(try world.journal.nightsElapsed(after: world.nightID, through: world.nightID) == 0)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-24")!, now: epoch.addingTimeInterval(86_400))
        #expect(try world.journal.nightsElapsed(after: world.nightID, through: night2) == 1)

        let night3 = try world.openNight(
            NightStart(rawValue: "2026-09-25")!, now: epoch.addingTimeInterval(2 * 86_400)
        )
        #expect(try world.journal.nightsElapsed(after: world.nightID, through: night3) == 2)
        // From the second Night's own perspective, only the third has elapsed.
        #expect(try world.journal.nightsElapsed(after: night2, through: night3) == 1)
    }

    @Test("A Card with no recorded replies has an empty unappliedCardReplies")
    func noRepliesIsEmpty() throws {
        let fixture = try JournalFixture()
        let world = try ReplyWorld(try fixture.open())
        #expect(try world.journal.unappliedCardReplies().isEmpty)
        #expect(try world.journal.cardReplies(questionID: world.questionID).isEmpty)
    }
}
