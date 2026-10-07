import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (roadmap P12.1): the `**Standing: un-adopted Cards:**` line
// and its ONE derivation, `journal.unadoptedNights(cardID:asOf:)`/`journal.unadoptedCards(asOf:)`,
// read by both the Night Summary and the Card's own Managed Block header. Reuses
// `NightCardJournalFixture`, `makeBoards()` and `nightCardNightStart` from NightCardTests.swift.

/// Inserts a Night row directly — these tests exercise the elapsed-Nights arithmetic against a
/// hand-built Night table, not through a full Act.
private func insertNightRow(
    _ journal: JournalStore, nightStart: NightStart, openedAt: Date, projectID: ProjectID
) throws {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                projectID.rawValue, nightStart.rawValue, NightMode.real.rawValue, NightState.closed.rawValue,
                JournalStore.timestamp(openedAt)
            ]
        )
    }
}

/// A Feature/Cycle/Card fixture's Journal ids.
private struct UnadoptedFixtureIDs {
    let featureID: Int64
    let cycleID: Int64
    let cardID: Int64
}

/// Inserts a Feature (closed), an archived Cycle, and a Blocked Card left behind — the un-adopted
/// shape `blockedCardsLeftByClosedFeatures()` and `unadoptedCards(asOf:)` both read.
@discardableResult
private func insertUnadoptedFixture(
    _ journal: JournalStore, featureIssueID: String, cardIssueID: String, archivedAt: Date,
    cardState: CardState = .blocked
) throws -> UnadoptedFixtureIDs {
    try journal.write { db in
        let createdAt = JournalStore.timestamp(archivedAt.addingTimeInterval(-3600))
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [featureIssueID, "closed", createdAt]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [featureID, createdAt, JournalStore.timestamp(archivedAt)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, cardIssueID, "backend", "card", 1, cardState.rawValue, 0, createdAt]
        )
        return UnadoptedFixtureIDs(featureID: featureID, cycleID: cycleID, cardID: db.lastInsertedRowID)
    }
}

@Suite("Night Summary: the un-adopted-Cards standing line (P12.1)")
struct NightSummaryStandingLinesTests {
    @Test("Elapsed Nights count only recorded Nights, skipping a Night that never opened")
    func elapsedNightsSkipsAGap() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let day1 = try #require(NightStart(rawValue: "2026-09-10"))
        let day2 = try #require(NightStart(rawValue: "2026-09-12"))
        // 2026-09-11 never ran: a gap, deliberately never inserted.
        let day3 = try #require(NightStart(rawValue: "2026-09-13"))
        let day4 = try #require(NightStart(rawValue: "2026-09-15"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let projectID = fixture.projectID
        try insertNightRow(journal, nightStart: day1, openedAt: base, projectID: projectID)
        try insertNightRow(
            journal, nightStart: day2, openedAt: base.addingTimeInterval(2 * 86400), projectID: projectID
        )
        try insertNightRow(
            journal, nightStart: day3, openedAt: base.addingTimeInterval(3 * 86400), projectID: projectID
        )
        try insertNightRow(
            journal, nightStart: day4, openedAt: base.addingTimeInterval(5 * 86400), projectID: projectID
        )

        // Archived between day2's opened_at and day3's: day2 is the closing Night.
        let archivedAt = base.addingTimeInterval(2 * 86400 + 3600)
        let seeded = try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-OLD", cardIssueID: "CARD-1", archivedAt: archivedAt
        )

        #expect(try journal.unadoptedNights(cardID: seeded.cardID, asOf: day3) == 1)
        #expect(try journal.unadoptedNights(cardID: seeded.cardID, asOf: day4) == 2)
    }

    @Test("Several un-adopted Cards are named individually")
    func severalCardsNamedIndividually() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())

        let archivedAt = night.openedAt
        try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-A", cardIssueID: "CARD-A", archivedAt: archivedAt
        )
        try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-B", cardIssueID: "CARD-B", archivedAt: archivedAt
        )

        let lines = try NightSummary.unadoptedCardLines(night: night, journal: journal)
        #expect(lines.contains { $0.contains("`CARD-A`") && $0.contains("`FEAT-A`") })
        #expect(lines.contains { $0.contains("`CARD-B`") && $0.contains("`FEAT-B`") })
    }

    @Test("A Shelved Card is absent; reopened, it returns with its count still running")
    func shelvedCardAbsentReopenedReturns() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1",
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        var night: NightRecord!
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                try journal.markCardShelved(
                    cardID: seeded.cardID, runID: context.runID, act: context.act, nightID: nil
                )
            }
        ).run()
        night = try #require(try journal.currentNight())

        let shelvedLines = try NightSummary.unadoptedCardLines(night: night, journal: journal)
        #expect(!shelvedLines.contains { $0.contains("`CARD-1`") })

        try journal.releaseActLease(runID: RunID())
        let secondNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: secondNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                try journal.restoreShelvedCard(
                    cardID: seeded.cardID, runID: context.runID, act: context.act, nightID: nil
                )
            }
        ).run()
        night = try #require(try journal.currentNight())

        let reopenedLines = try NightSummary.unadoptedCardLines(night: night, journal: journal)
        #expect(reopenedLines.contains { $0.contains("`CARD-1`") && $0.contains("`FEAT-1`") })
    }

    @Test("The Night Summary line and the Card's Managed Block header carry the same figure")
    func summaryLineAndManagedBlockHeaderAgree() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())
        let seeded = try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1",
            archivedAt: night.openedAt
        )

        let summaryLine = try #require(
            try NightSummary.unadoptedCardLines(night: night, journal: journal).first { $0.contains("`CARD-1`") }
        )
        let unadopted = try #require(
            try journal.unadoptedCards(asOf: night.nightStart).first { $0.card.id == seeded.cardID }
        )
        let block = CardManagedBlock(
            kind: "card", repository: "backend", state: .blocked, lanePosition: 1, laneLength: 1,
            brief: ArchitecturalBrief(prose: "", transcriptions: []), definitionOfDone: [], attempts: [],
            unadoptedStanding: UnadoptedStanding(
                closedFeatureIssueID: unadopted.closedFeatureIssueID, elapsedNights: unadopted.elapsedNights
            )
        )
        let headerLine = try #require(block.render().split(separator: "\n").first { $0.hasPrefix("**State:**") })

        #expect(summaryLine.contains("un-adopted for \(unadopted.elapsedNights) Night"))
        #expect(headerLine.contains("un-adopted for \(unadopted.elapsedNights) Night"))
    }

    @Test("Night completion refreshes the un-adopted Card's Managed Block header on the board, and releases the Lease")
    func refreshReachesBoardAndReleasesLease() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let seeded = try insertUnadoptedFixture(
            journal, featureIssueID: "FEAT-1", cardIssueID: "CARD-1",
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await boards.writing.seed(
            issue: "CARD-1", description: ManagedBlockFence.initialDescription(rendered: "placeholder")
        )

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "CARD-1")))
        let description = try #require(issue.description)
        #expect(description.contains("un-adopted for"))
        #expect(description.contains("since Feature `FEAT-1` closed"))
        #expect(try journal.currentCardLease(cardID: seeded.cardID) == nil)
    }
}
