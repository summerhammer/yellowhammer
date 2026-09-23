import Domain
import Foundation
import Testing

@testable import Engine
@testable import EngineCommand
@testable import Journal

// roadmap P11.6 (bounds overview): the Night Summary's `**Bounds:**` section (this Night's proximity
// to each of the three Bounds, always present on a completed block) and `**Standing items:**` section
// (every currently promoted Refusal and Card, rendered whenever any exist — not only the Night of
// promotion). Rendering only: never model-authored content.

/// Inserts a Feature/Cycle/Card fixture in Waiting on You, for the failed-Adoption promotion lines.
@discardableResult
private func insertBoundsSummaryCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-HOST", "selected", JournalStore.timestamp(Date())]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(Date())]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card
                (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "backend", "card", 1, CardState.waitingOnYou.rawValue, 0,
                JournalStore.timestamp(Date())
            ]
        )
        return db.lastInsertedRowID
    }
}

/// Seeds one re-selection, a promoted Refusal and a promoted Card's failed Adoption against `nightID`,
/// asserting each promotion's marker along the way — split out of
/// `acceptCompletionRendersBoundsAndStandingItems` to keep that test within the length limit.
private func seedBoundsSummaryEvents(_ journal: JournalStore, nightID: Int64) throws {
    let noise = RunID()
    try journal.append(
        .featureReselected(depth: 1, afterRefusalOf: "FEAT-OLD", reselectionsMax: 2),
        act: .author, runID: noise, nightID: nightID
    )
    let refusalOutcome = try journal.recordRefusal(
        feature: try #require(FeatureName(rawValue: "FEAT-1")), content: "thin",
        consecutiveRefusalsMax: 1, nightID: nightID, act: .author, runID: noise
    )
    #expect(refusalOutcome.record.standingItemNightID == nil)
    let secondRefusal = try journal.recordRefusal(
        feature: try #require(FeatureName(rawValue: "FEAT-1")), content: "still thin",
        consecutiveRefusalsMax: 1, nightID: nightID, act: .author, runID: noise
    )
    #expect(secondRefusal.record.standingItemNightID == nightID)

    let cardID = try insertBoundsSummaryCard(journal, issueID: "BACK-1")
    _ = try journal.recordAdoptionRefusal(
        cardID: cardID, nightID: nightID, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1,
        act: .author, runID: noise
    )
    let cardPromotion = try journal.recordAdoptionRefusal(
        cardID: cardID, nightID: nightID, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1,
        act: .author, runID: noise
    )
    #expect(try journal.card(id: cardPromotion.cardID).divergenceStandingNightID == nightID)
}

@Suite("Night Summary: Bounds and Standing items (P11.6)")
struct BoundsSummaryTests {
    @Test("NightCardBlock.completed always renders the Bounds section when bounds lines are given")
    func completedRendersBoundsSection() {
        let night = NightRecord(
            id: 1, projectID: ProjectID(rawValue: "fixture")!, nightStart: nightCardNightStart,
            mode: .real, state: .closed, nightCardIssueID: "NIGHT-1", openedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 10), closeReason: .nightEnd, verdict: nil, triagedAt: nil
        )

        let withoutBounds = NightCardBlock.completed(night: night, projectID: night.projectID)
        #expect(!withoutBounds.contains("**Bounds:**"))
        #expect(!withoutBounds.contains("**Standing items:**"))

        let withBounds = NightCardBlock.completed(
            night: night, projectID: night.projectID,
            bounds: ["`reselections_max` 2: 0 re-selections used this Night."],
            standingItems: [
                "Feature `FEAT-1` has been refused 2 times in a row, past `consecutive_refusals_max` 1 — " +
                    "a standing decision."
            ]
        )
        #expect(withBounds.contains("**Bounds:**"))
        #expect(withBounds.contains("- `reselections_max` 2: 0 re-selections used this Night."))
        #expect(withBounds.contains("**Standing items:**"))
        #expect(withBounds.contains("Feature `FEAT-1` has been refused 2 times in a row"))
    }

    @Test("""
        acceptCompletion reports this Night's re-selections, refusals and failed Adoptions, and every \
        live standing item
        """)
    func acceptCompletionRendersBoundsAndStandingItems() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let night = try #require(try journal.currentNight())
        try seedBoundsSummaryEvents(journal, nightID: night.id)

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            nightCardBounds: NightCardMaintenance.Bounds(
                reselectionsMax: 2, consecutiveRefusalsMax: 1, failedAdoptionsMax: 1
            ),
            work: { _ in }
        ).run()

        let issue = try #require(await boards.writing.liveIssues.first)
        let description = try #require(issue.description)

        #expect(description.contains("**Bounds:**"))
        #expect(description.contains("`reselections_max` 2: 1 re-selection used this Night."))
        #expect(description.contains("Feature `FEAT-1`: 2 of 1 consecutive Refusals"))
        #expect(description.contains("Card `BACK-1`: 2 of 1 consecutive failed Adoptions"))

        #expect(description.contains("**Standing items:**"))
        #expect(description.contains(
            "Feature `FEAT-1` has been refused 2 times in a row, past `consecutive_refusals_max` 1"
        ))
        #expect(description.contains(
            "Card `BACK-1` has failed Adoption 2 times in a row, past `failed_adoptions_max` 1"
        ))
    }

    @Test("A standing item persists on a later, otherwise quiet Night")
    func standingItemPersistsOnQuietNight() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let firstNight = try #require(try journal.currentNight())
        let noise = RunID()
        _ = try journal.recordRefusal(
            feature: try #require(FeatureName(rawValue: "FEAT-1")), content: "thin",
            consecutiveRefusalsMax: 1, nightID: firstNight.id, act: .author, runID: noise
        )
        _ = try journal.recordRefusal(
            feature: try #require(FeatureName(rawValue: "FEAT-1")), content: "still thin",
            consecutiveRefusalsMax: 1, nightID: firstNight.id, act: .author, runID: noise
        )
        try journal.releaseActLease(runID: noise)

        let nextNightStart = try #require(NightStart(rawValue: "2026-09-16"))
        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nextNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            nightCardBounds: NightCardMaintenance.Bounds(consecutiveRefusalsMax: 1),
            work: { _ in }
        ).run()

        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "Night \(nextNightStart)" })
        let description = try #require(issue.description)
        #expect(description.contains("**Standing items:**"))
        #expect(description.contains(
            "Feature `FEAT-1` has been refused 2 times in a row, past `consecutive_refusals_max` 1"
        ))
        // Quiet on the second Night's own Bounds: no re-selection, Refusal or failed Adoption happened.
        #expect(description.contains("no Refusal this Night"))
    }
}
