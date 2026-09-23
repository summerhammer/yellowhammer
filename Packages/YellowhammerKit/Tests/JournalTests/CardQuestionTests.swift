import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Card Question table (roadmap P11.1; spec: bounds/escalate-a-question-to-the-operator): a worker
// pass's question, recorded before the Card moves to Waiting on You.

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

/// A Journal with one Card, a held Act Lease, one open Night, and one Attempt recorded on the Card.
private struct QuestionWorld {
    let journal: JournalStore
    let runID = RunID()
    let cardID: Int64
    let nightID: Int64
    let attemptID: Int64

    init(_ journal: JournalStore) throws {
        self.journal = journal
        cardID = try QuestionWorld.insertFixtureCard(journal)
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        nightID = try journal.openNight(nightStart: nightStart, mode: .rehearsal, act: .build, runID: runID, now: epoch)
            .night.id
        attemptID = try journal.recordAttempt(
            cardID: cardID, route: route, runID: runID, act: .build, nightID: nightID, now: epoch
        ).id
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

@Suite("Card Question in the Journal (P11.1)")
struct CardQuestionTests {
    @Test("Recording a question round-trips its fields")
    func recordingRoundTrips() throws {
        let fixture = try JournalFixture()
        let world = try QuestionWorld(try fixture.open())

        let record = try world.journal.recordCardQuestion(
            cardID: world.cardID, attemptID: world.attemptID, question: "Which endpoint should this call?",
            commentClientID: "client-1", nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        #expect(record.cardID == world.cardID)
        #expect(record.attemptID == world.attemptID)
        #expect(record.nightID == world.nightID)
        #expect(record.question == "Which endpoint should this call?")
        #expect(record.commentClientID == "client-1")
    }

    @Test("Recording a question appends CardQuestionAsked")
    func recordingAppendsTheEvent() throws {
        let fixture = try JournalFixture()
        let world = try QuestionWorld(try fixture.open())

        _ = try world.journal.recordCardQuestion(
            cardID: world.cardID, attemptID: world.attemptID, question: "What should the timeout be?",
            commentClientID: nil, nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )

        let events = try world.journal.events(ofType: .cardQuestionAsked)
        #expect(events.count == 1)
        guard case .cardQuestionAsked(let cardID, let issueID, let attemptID) = events[0].event else {
            Issue.record("expected cardQuestionAsked")
            return
        }
        #expect(cardID == world.cardID)
        #expect(issueID == "ENG-1")
        #expect(attemptID == world.attemptID)
    }

    @Test("latestCardQuestion picks the newest question")
    func latestPicksNewest() throws {
        let fixture = try JournalFixture()
        let world = try QuestionWorld(try fixture.open())

        _ = try world.journal.recordCardQuestion(
            cardID: world.cardID, attemptID: world.attemptID, question: "First question?",
            commentClientID: nil, nightID: world.nightID, act: .build, runID: world.runID, now: epoch
        )
        try world.journal.endAttempt(
            attemptID: world.attemptID, ending: .question, runID: world.runID, act: .build, nightID: world.nightID,
            now: epoch
        )
        let secondAttempt = try world.journal.recordAttempt(
            cardID: world.cardID, route: route, runID: world.runID, act: .build, nightID: world.nightID,
            now: epoch.addingTimeInterval(60)
        ).id
        let second = try world.journal.recordCardQuestion(
            cardID: world.cardID, attemptID: secondAttempt, question: "Second question?",
            commentClientID: "client-2", nightID: world.nightID, act: .build, runID: world.runID,
            now: epoch.addingTimeInterval(60)
        )

        let latest = try #require(try world.journal.latestCardQuestion(cardID: world.cardID))
        #expect(latest.id == second.id)
        #expect(latest.question == "Second question?")
    }

    @Test("A Card with no question has nil latestCardQuestion")
    func noQuestionIsNil() throws {
        let fixture = try JournalFixture()
        let world = try QuestionWorld(try fixture.open())
        #expect(try world.journal.latestCardQuestion(cardID: world.cardID) == nil)
    }
}
