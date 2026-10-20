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

/// How a seeded Act ended: its `ActEnded`, its `ActIncomplete`, or neither (it crashed).
enum SeededRunEnding {
    case ended, halted, unterminated
}

/// The instant of an ISO-8601 string such as `2026-10-08T00:01:00Z`.
func seededInstant(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

/// Seeds one Act of `night` into the Journal: `ActStarted` at `startedAt`, an optional `FlushFiringRan` (a
/// flush firing), and the ending. Returns its run id.
@discardableResult
func appendSeededRun(
    to journal: JournalStore, night: NightRecord, startedAt: String, ending: SeededRunEnding,
    act: Act = .land, flush: FlushFiringOutcome? = nil
) throws -> RunID {
    let runID = RunID()
    let start = try seededInstant(startedAt)
    try journal.append(.actStarted, act: act, runID: runID, nightID: night.id, now: start)
    if let flush {
        try journal.append(
            .flushFiringRan(outcome: flush, detail: nil), act: act, runID: runID, nightID: night.id,
            now: start.addingTimeInterval(1)
        )
    }
    switch ending {
    case .ended:
        try journal.append(.actEnded, act: act, runID: runID, nightID: night.id, now: start.addingTimeInterval(2))
    case .halted:
        try journal.append(
            .actIncomplete(reason: "board unreachable"), act: act, runID: runID, nightID: night.id,
            now: start.addingTimeInterval(2)
        )
    case .unterminated:
        break
    }
    return runID
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

    @Test("A Night whose only authoring event is a release gate hold reads as quiet")
    func releaseGateHoldReadsAsQuiet() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(
            .authoringReleaseGateHeld(
                featureName: "Add login", consumer: "backend", producer: "contracts", producerFeatureIssueID: "FEAT-K"
            ),
            act: .author, runID: RunID(), nightID: night.id
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

    @Test("A last Act that crashed leads the verdict with crashed, promoted to the front")
    func crashedEndingIsPromotedToFront() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:01:00Z", ending: .unterminated)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "crashed · no decisions waiting · did not advance")
    }

    @Test("Lease and Card reclaims, and a previous Night's opened-and-died event, no longer crash the ending")
    func reclaimsDoNotCrashTheEnding() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try journal.append(
            .leaseReclaimed(previousRunID: RunID(), previousAct: .build, expiredAt: Date()),
            act: .land, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .cardLeaseReclaimed(cardID: 1, previousRunID: RunID(), expiredAt: Date()),
            act: .land, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .cardReclaimed(
                cardID: 1, issueID: "CARD-1", previousRunID: RunID(), attemptID: nil, outcome: nil,
                routeExcluded: false
            ),
            act: .land, runID: RunID(), nightID: night.id
        )
        try journal.append(
            .nightOpenedAndDied(nightID: 99, nightStart: nightCardNightStart),
            act: .land, runID: RunID(), nightID: night.id
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "no decisions waiting · did not advance · closed")
    }

    @Test("A last Act that halted leads the verdict with halted, promoted to the front")
    func haltedEndingIsPromotedToFront() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:01:00Z", ending: .halted)

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line == "halted · no decisions waiting · did not advance")
    }

    @Test("A halted Act that a later Act recovered does not halt the ending: the closing land renders closed")
    func recoveredHaltRendersClosed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:01:00Z", ending: .halted)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:15:00Z", ending: .ended)
        // The closing land renders its verdict before its own terminal event is written.
        let closingLand = try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:00:00Z", ending: .unterminated
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: closingLand)
        #expect(line == "no decisions waiting · did not advance · closed")
    }

    @Test("The Act rendering the verdict counts as ended, but the same unterminated Act does not for a later render")
    func renderingRunCountsAsEnded() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        let running = try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:00:00Z", ending: .unterminated
        )

        #expect(
            try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: running)
                == "no decisions waiting · did not advance · closed"
        )
        #expect(
            try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: RunID())
                == "crashed · no decisions waiting · did not advance"
        )
    }

    @Test("A closing land that halted, then closed by a flush firing, still renders halted")
    func haltedClosingLandClosedByFlushRendersHalted() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T03:00:00Z", ending: .halted)
        let flush = try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:06:00Z", ending: .unterminated,
            flush: .closedNight
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: flush)
        #expect(line == "halted · no decisions waiting · did not advance")
    }

    @Test("A closing land that crashed, then closed by a flush firing, renders crashed, not closed")
    func crashedClosingLandClosedByFlushRendersCrashed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:15:00Z", ending: .ended)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T03:00:00Z", ending: .unterminated)
        let flush = try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:06:00Z", ending: .unterminated,
            flush: .closedNight
        )

        let line = try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: flush)
        #expect(line == "crashed · no decisions waiting · did not advance")
    }

    @Test("A stood-down closing land (no ActStarted) closed by a flush firing: the last real Act decides")
    func standDownClosingLandRendersTheLastRealRun() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T00:15:00Z", ending: .ended)
        let flush = try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:06:00Z", ending: .unterminated,
            flush: .closedNight
        )
        #expect(
            try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: flush)
                == "no decisions waiting · did not advance · closed"
        )

        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T03:10:00Z", ending: .halted)
        #expect(
            try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: flush)
                == "halted · no decisions waiting · did not advance"
        )
    }

    @Test("A flush firing neither fails nor recovers: a halted Act then an ended flush firing still reads halted")
    func flushFiringsRecoverNothing() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let night = try await openNightForVerdictTest(journal: journal, board: board)
        try appendSeededRun(to: journal, night: night, startedAt: "2026-10-08T03:00:00Z", ending: .halted)
        try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:06:00Z", ending: .ended, flush: .stillPending
        )
        try appendSeededRun(
            to: journal, night: night, startedAt: "2026-10-08T03:09:00Z", ending: .halted, flush: .failed
        )

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

    @Test("A landed in-flight Feature is named in the decisions phrase, with its outstanding merges")
    func landedInFlightFeatureIsNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertVerdictFixture(journal, cardState: .blocked)
        let night = try await openNightForVerdictTest(journal: journal, board: board) { context in
            try journal.markCycleLanded(cycleID: seeded.cycleID, runID: context.runID)
        }

        let line = try NightSummary.verdictLine(night: night, journal: journal)
        #expect(line.contains(", Feature `FEAT-1` in flight"))
        #expect(!line.contains("unsettled"))
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
