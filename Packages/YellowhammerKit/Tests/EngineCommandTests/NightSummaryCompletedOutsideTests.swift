import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary (ruling OQ199 item 9, 2026-11-08): the Night Summary names each
// Work Card read as Operator Done once, on the Night it was read, under `**Completed outside Yellowhammer:**`,
// apart from the Work Cards Yellowhammer finished. Reuses `NightCardJournalFixture`, `makeBoards()` and
// `nightCardNightStart` from NightCardTests.swift.

private let operatorDoneRoute = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!

/// Opens the Project's one Night the way the author Act does; `seed` runs while the Act Lease is held.
private func openNightForCompletedOutsideTest(
    journal: JournalStore, nightStart: NightStart = nightCardNightStart,
    seed: @escaping @Sendable (ActContext) throws -> Void = { _ in }
) async throws -> NightRecord {
    let boards = try await makeBoards()
    let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    try await EngineInvocation(
        act: .author, mode: .real, nightStart: nightStart, journal: journal,
        trigger: .forced, runID: RunID(), board: board, work: { context in try seed(context) }
    ).run()
    return try #require(try journal.currentNight())
}

/// Inserts a Feature/Cycle/Card fixture and returns the Card's Journal id. `archived` archives the Cycle
/// and closes the Feature — the un-adopted shape when the Card is Blocked.
@discardableResult
private func insertCompletedOutsideCard(
    _ journal: JournalStore, cardIssueID: String = "CARD-1",
    repository: String = "backend", authoredOrder: Int = 1, cardState: CardState = .todo,
    blockReason: BlockReason? = nil, archivedAt: Date? = nil
) throws -> Int64 {
    try journal.write { db in
        let timestamp = JournalStore.timestamp(archivedAt?.addingTimeInterval(-3600) ?? Date())
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-\(cardIssueID)", archivedAt == nil ? "selected" : "closed", timestamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [featureID, timestamp, archivedAt.map(JournalStore.timestamp)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, cardIssueID, repository, "card", authoredOrder, cardState.rawValue,
                blockReason?.rawValue, 0, timestamp
            ]
        )
        return db.lastInsertedRowID
    }
}

/// Marks the Card Operator Done under the Act's Lease, stamped with this Night's id.
private func markOperatorDone(_ journal: JournalStore, cardID: Int64, context: ActContext) throws {
    try journal.markCardOperatorDone(
        cardID: cardID, runID: context.runID, act: context.act, nightID: context.night.id
    )
}

@Suite("Night Summary: Completed outside Yellowhammer (OQ199 item 9)")
struct NightSummaryCompletedOutsideTests {
    @Test("A Card read as Operator Done is named once, with the state the Operator's Done replaced")
    func operatorDoneCardIsNamedOnce() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCompletedOutsideCard(journal, cardState: .blocked, blockReason: .checkFailure)
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            try markOperatorDone(journal, cardID: cardID, context: context)
        }

        #expect(try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal) == [
            "`CARD-1` — moved to Done on the board by the Operator (was Blocked)."
        ])
    }

    @Test("A Card read as Operator Done twice in one Night is named once")
    func operatorDoneTwiceIsNamedOnce() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCompletedOutsideCard(journal)
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            try markOperatorDone(journal, cardID: cardID, context: context)
            // The second read throws on a Done Card, so the Card leaves Done first.
            try journal.write { db in
                try db.execute(
                    sql: "UPDATE card SET state = ?, block_reason = ? WHERE id = ?",
                    arguments: [CardState.blocked.rawValue, BlockReason.checkFailure.rawValue, cardID]
                )
            }
            try markOperatorDone(journal, cardID: cardID, context: context)
        }

        let lines = try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal)
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("`CARD-1` — moved to Done on the board by the Operator") == true)
    }

    @Test("A Card whose open Attempt was cancelled reads `Done (done by the Operator)` under Cards")
    func cancelledAttemptCardIsWordedAsOperatorDone() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCompletedOutsideCard(journal)
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            try journal.recordAttempt(
                cardID: cardID, route: operatorDoneRoute, runID: context.runID, act: context.act,
                nightID: context.night.id
            )
            try markOperatorDone(journal, cardID: cardID, context: context)
        }

        let cardLines = try NightSummary.cardLines(night: night, journal: journal)
        #expect(cardLines.count == 1)
        #expect(cardLines.first?.hasPrefix("`CARD-1` — Done (done by the Operator) · ") == true)
        #expect(try NightSummary.cardShortLines(night: night, journal: journal) == [
            "`CARD-1` — Done (done by the Operator) · 1 Attempt this Night — see the Journal."
        ])
        #expect(try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal) == [
            "`CARD-1` — moved to Done on the board by the Operator (was Todo)."
        ])
    }

    @Test("A Card Yellowhammer moved to Done is not named, and reads plain Done under Cards")
    func yellowhammerDoneIsNotNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCompletedOutsideCard(journal)
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            try journal.transitionCard(
                cardID: cardID, to: .done, runID: context.runID, act: context.act, nightID: context.night.id
            )
        }

        #expect(try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal).isEmpty)
        #expect(try NightSummary.cardLines(night: night, journal: journal) == [
            "`CARD-1` — Done · no Attempt this Night."
        ])
    }

    @Test("An Operator Done event with another Night's id, or with no Night id, is not named")
    func otherNightOrNoNightIsNotNamed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let otherNight = try insertCompletedOutsideCard(journal, cardIssueID: "CARD-OTHER", authoredOrder: 1)
        let noNight = try insertCompletedOutsideCard(journal, cardIssueID: "CARD-NONE", authoredOrder: 2)
        let earlierStart = try #require(NightStart(rawValue: "2026-09-14"))
        let earlier = try await openNightForCompletedOutsideTest(
            journal: journal, nightStart: earlierStart
        ) { context in
            try markOperatorDone(journal, cardID: otherNight, context: context)
        }
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            try journal.markCardOperatorDone(
                cardID: noNight, runID: context.runID, act: context.act, nightID: nil
            )
        }

        #expect(earlier.id != night.id)
        #expect(try NightSummary.completedOutsideYellowhammerLines(night: earlier, journal: journal) == [
            "`CARD-OTHER` — moved to Done on the board by the Operator (was Todo)."
        ])
        #expect(try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal).isEmpty)
    }

    @Test("Several Cards are named in repository, then authored, order")
    func severalCardsAreOrdered() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let web = try insertCompletedOutsideCard(journal, cardIssueID: "CARD-W", repository: "web")
        let second = try insertCompletedOutsideCard(journal, cardIssueID: "CARD-B2", authoredOrder: 2)
        let first = try insertCompletedOutsideCard(journal, cardIssueID: "CARD-B1", authoredOrder: 1)
        let night = try await openNightForCompletedOutsideTest(journal: journal) { context in
            for cardID in [web, second, first] {
                try markOperatorDone(journal, cardID: cardID, context: context)
            }
        }

        let lines = try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal)
        #expect(lines.map { $0.prefix(9) } == ["`CARD-B1`", "`CARD-B2`", "`CARD-W` "])
    }

    @Test("The section renders between Cards and Dispositions, and has no header when empty")
    func sectionPlacement() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let night = try await openNightForCompletedOutsideTest(journal: journal)
        let projectID = fixture.projectID

        let rendered = NightCardBlock.completed(
            night: night, projectID: projectID, cardLines: ["card line"],
            completedOutsideYellowhammer: ["outside line"], dispositionLines: ["disposition line"]
        )
        let cards = try #require(rendered.range(of: "**Cards:**"))
        let outside = try #require(rendered.range(of: "**Completed outside Yellowhammer:**\n- outside line"))
        let dispositions = try #require(rendered.range(of: "**Dispositions:**"))
        #expect(cards.upperBound <= outside.lowerBound)
        #expect(outside.upperBound <= dispositions.lowerBound)

        let empty = NightCardBlock.completed(
            night: night, projectID: projectID, cardLines: ["card line"], dispositionLines: ["disposition line"]
        )
        #expect(!empty.contains("Completed outside Yellowhammer"))
        #expect(empty == NightCardBlock.completed(
            night: night, projectID: projectID, cardLines: ["card line"], completedOutsideYellowhammer: [],
            dispositionLines: ["disposition line"]
        ))
    }

    // Draft derivation D8 (not ruled): an un-adopted Card read as Operator Done is no longer un-adopted.
    @Test("A Blocked, un-adopted Card read as Operator Done leaves the un-adopted Cards")
    func operatorDoneLeavesUnadoptedCards() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCompletedOutsideCard(
            journal, cardState: .blocked, blockReason: .checkFailure,
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let before = try await openNightForCompletedOutsideTest(journal: journal)
        #expect(try NightSummary.unadoptedCardLines(night: before, journal: journal)
            .contains { $0.contains("`CARD-1`") })

        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in try markOperatorDone(journal, cardID: cardID, context: context) }
        ).run()
        let night = try #require(try journal.currentNight())

        #expect(try !NightSummary.unadoptedCardLines(night: night, journal: journal)
            .contains { $0.contains("`CARD-1`") })
        #expect(try NightSummary.completedOutsideYellowhammerLines(night: night, journal: journal) == [
            "`CARD-1` — moved to Done on the board by the Operator (was Blocked)."
        ])
    }
}
