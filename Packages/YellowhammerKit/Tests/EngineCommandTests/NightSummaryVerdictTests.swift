import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P12.1): the Night Summary's `**Verdict:**` line —
// one constant-time sentence, closed vocabulary, joined by " · ", never a list, never growing with the
// Night. Reuses `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from
// NightCardTests.swift.

/// Opens the Project's one Night the way the author Act does, and hands back the recorded row. `seed`
/// runs inside the Act's `work` closure, while its Act-scoped lease is still held — any Journal write
/// that revalidates the lease (`recordAuthoringNoWorkAvailable`, `markCycleLanded`, ...) must happen
/// there, since `.run()` releases the lease before returning.
private func openNightForVerdictTest(
    journal: JournalStore, board: ActBoard, seed: @escaping @Sendable (ActContext) throws -> Void = { _ in }
) async throws -> NightRecord {
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
        trigger: .forced, runID: RunID(), board: board, work: { context in try seed(context) }
    ).run()
    return try #require(try journal.currentNight())
}

/// A Feature/Cycle/Card fixture's Journal ids.
private struct VerdictFixtureIDs {
    let featureID: Int64
    let cycleID: Int64
    let cardID: Int64
}

/// Inserts a Feature/Cycle/Card fixture, returning their Journal ids.
@discardableResult
private func insertVerdictFixture(
    _ journal: JournalStore, featureIssueID: String = "FEAT-1", cardIssueID: String = "CARD-1",
    cardState: CardState = .todo
) throws -> VerdictFixtureIDs {
    try journal.write { db in
        let timestamp = JournalStore.timestamp(Date())
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [featureIssueID, "selected", timestamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, cardIssueID, "backend", "card", 1, cardState.rawValue, 0, timestamp]
        )
        return VerdictFixtureIDs(featureID: featureID, cycleID: cycleID, cardID: db.lastInsertedRowID)
    }
}

@Suite("Night Summary: the constant-time Verdict line (P12.1)")
struct NightSummaryVerdictTests {
    @Test("A silent Night is quiet, no decisions, closed")
    func silentNightIsQuietClosedNoDecisions() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · did not advance · closed")
    }

    @Test("The idle verdict reads back as 'did not advance — idle'")
    func idleVerdict() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board) { context in
            _ = try journal.recordAuthoringNoWorkAvailable(
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        }

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · did not advance — idle · closed")
    }

    @Test("A quiet authoring reason reads back as 'did not advance — quiet'")
    func quietAuthoringReason() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(
            .authoringSkippedFeatureInFlight(featureIssueID: "FEAT-1"), act: .author, runID: RunID(), nightID: night.id
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · did not advance — quiet · closed")
    }

    @Test("A Card state transition reads back as 'advanced without landing'")
    func advancedWithoutLanding() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(
            .cardStateTransitioned(
                cardID: 1, issueID: "CARD-1", from: .todo, to: .inProgress, waitingReason: nil, blockReason: nil
            ),
            act: .build, runID: RunID(), nightID: night.id
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · advanced without landing · closed")
    }

    @Test("A Cycle landed with no holes reads back as 'landed'")
    func landedCleanly() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        let seeded = try insertVerdictFixture(journal, cardState: .done)
        try journal.append(.cycleLanded(cycleID: seeded.cycleID), act: .land, runID: RunID(), nightID: night.id)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · landed · closed")
    }

    @Test("A Cycle landed with lane holes reads back as a Partial Landing")
    func landedPartially() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        let seeded = try insertVerdictFixture(journal, cardState: .blocked)
        try journal.append(.cycleLanded(cycleID: seeded.cycleID), act: .land, runID: RunID(), nightID: night.id)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "1 decision waiting · landed partially — Partial Landing · closed")
    }

    @Test("A reclaimed lease crashes the ending and is promoted to the front")
    func crashedEndingIsPromotedToFront() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(
            .leaseReclaimed(previousRunID: RunID(), previousAct: .build, expiredAt: Date()),
            act: .land, runID: RunID(), nightID: night.id
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "crashed · no decisions waiting · did not advance")
    }

    @Test("An incomplete Act halts the ending and is promoted to the front")
    func haltedEndingIsPromotedToFront() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(.actIncomplete(reason: "board unreachable"), act: .build, runID: RunID(), nightID: night.id)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "halted · no decisions waiting · did not advance")
    }

    @Test("Decisions waiting counts the in-flight Cycle's Blocked and Waiting on You Cards")
    func decisionsWaitingCountsLaneHoles() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try insertVerdictFixture(journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1", cardState: .blocked)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "1 decision waiting · did not advance · closed")
    }

    @Test("An unsettled landed Feature is named in the decisions phrase")
    func unsettledFeatureIsNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertVerdictFixture(journal, cardState: .blocked)
        let night = try await openNightForVerdictTest(journal: journal, board: board) { context in
            try journal.markCycleLanded(cycleID: seeded.cycleID, runID: context.runID)
        }

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line.contains(", held by unsettled Feature `FEAT-1`"))
    }

    @Test("The Verdict line's shape does not grow with the number of Cards touched this Night")
    func verdictLineShapeIsConstant() async throws {
        let smallFixture = try NightCardJournalFixture(project: "small")
        let smallJournal = try smallFixture.open()
        let smallBoards = try await makeBoards()
        let smallBoard = ActBoard(
            reading: FakeReadingBoard([]), writing: smallBoards.writing, provisioning: smallBoards.provisioning
        )
        let route = try #require(Route(cli: "codex", model: "gpt-5.4", effort: "medium"))
        let smallNight = try await openNightForVerdictTest(journal: smallJournal, board: smallBoard)
        try smallJournal.append(
            .attemptEnded(
                cardID: 1, issueID: "CARD-1", attemptID: 1, route: route, outcome: "success", routeExcluded: false
            ),
            act: .build, runID: RunID(), nightID: smallNight.id
        )
        let smallLine = try NightSummary.verdictLine(night: smallNight, journal: smallJournal)

        let bigFixture = try NightCardJournalFixture(project: "big")
        let bigJournal = try bigFixture.open()
        let bigBoards = try await makeBoards()
        let bigBoard = ActBoard(
            reading: FakeReadingBoard([]), writing: bigBoards.writing, provisioning: bigBoards.provisioning
        )
        let bigNight = try await openNightForVerdictTest(journal: bigJournal, board: bigBoard)
        for cardID in Int64(1)...50 {
            try bigJournal.append(
                .attemptEnded(
                    cardID: cardID, issueID: "CARD-\(cardID)", attemptID: cardID, route: route,
                    outcome: "success", routeExcluded: false
                ),
                act: .build, runID: RunID(), nightID: bigNight.id
            )
        }
        let bigLine = try NightSummary.verdictLine(night: bigNight, journal: bigJournal)

        #expect(smallLine == bigLine)
        #expect(!bigLine.contains("CARD-"))
    }
}
