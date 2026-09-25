import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P11.6 (bounds/overview): the Divergence promotion Bound. A Card is promoted to
// a standing item once its `failed_adoptions` count exceeds `failedAdoptionsMax` — visibility only: no
// state, counter or budget change, and nothing written to the board. `recordAdoptionRefusal` itself is
// exercised end to end through the author Act in AdoptionRevalidationTests.swift (EngineCommandTests);
// these assert the promotion's own arithmetic against the Journal directly.

private struct AdoptionPromotionFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-adoption-promotion-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let promotionEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@discardableResult
private func insertPromotionCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-HOST", "selected", JournalStore.timestamp(promotionEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(promotionEpoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "backend", "card", 1, CardState.waitingOnYou.rawValue, 0,
                JournalStore.timestamp(promotionEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@discardableResult
private func openPromotionNight(_ journal: JournalStore, nightStart: String, previous: RunID? = nil) throws -> Int64 {
    if let previous {
        try journal.releaseActLease(runID: previous)
    }
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        Issue.record("Could not claim the Act Lease")
        return 0
    }
    let opening = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: nightStart)), mode: .rehearsal, act: .author, runID: runID
    )
    return opening.night.id
}

@Suite("Divergence promotion, failedAdoptionsMax = 1 (P11.6)")
struct AdoptionRefusalPromotionTests {
    @Test("Two failed Adoptions promote once; state and counters are otherwise unchanged")
    func promotesOnceOnSecondFailure() throws {
        let fixture = try AdoptionPromotionFixture()
        let journal = try fixture.open()
        let cardID = try insertPromotionCard(journal, issueID: "BACK-1")
        let night = try openPromotionNight(journal, nightStart: "2026-09-15")

        let first = try journal.recordAdoptionRefusal(
            cardID: cardID, nightID: night, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1
        )
        #expect(first.cardID == cardID)
        var card = try journal.card(id: cardID)
        #expect(card.failedAdoptions == 1)
        #expect(card.divergenceStandingNightID == nil)
        #expect(card.state == .waitingOnYou)
        #expect(try journal.events(ofType: .cardPromotedToStandingItem).isEmpty)

        _ = try journal.recordAdoptionRefusal(
            cardID: cardID, nightID: night, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1
        )
        card = try journal.card(id: cardID)
        #expect(card.failedAdoptions == 2)
        #expect(card.divergenceStandingNightID == night)
        #expect(card.state == .waitingOnYou)
        let events = try journal.events(ofType: .cardPromotedToStandingItem)
        #expect(events.count == 1)
        guard case .cardPromotedToStandingItem(let promotedCardID, let issueID, let failed, let bound) =
            events[0].event
        else {
            Issue.record("expected cardPromotedToStandingItem")
            return
        }
        #expect(promotedCardID == cardID)
        #expect(issueID == "BACK-1")
        #expect(failed == 2)
        #expect(bound == 1)

        let standing = try journal.standingDivergenceCards()
        #expect(standing.map(\.issueID) == ["BACK-1"])
    }

    @Test("A clean Adoption clears the marker")
    func cleanAdoptionClearsMarker() throws {
        let fixture = try AdoptionPromotionFixture()
        let journal = try fixture.open()
        let cardID = try insertPromotionCard(journal, issueID: "BACK-1")
        let night = try openPromotionNight(journal, nightStart: "2026-09-15")

        _ = try journal.recordAdoptionRefusal(
            cardID: cardID, nightID: night, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1
        )
        _ = try journal.recordAdoptionRefusal(
            cardID: cardID, nightID: night, featureName: "FEAT-NEW", staleBlocks: [], failedAdoptionsMax: 1
        )
        #expect(try journal.card(id: cardID).divergenceStandingNightID != nil)

        try journal.resetFailedAdoptions(cardID: cardID)

        let card = try journal.card(id: cardID)
        #expect(card.failedAdoptions == 0)
        #expect(card.divergenceStandingNightID == nil)
        #expect(try journal.standingDivergenceCards().isEmpty)
    }
}

@Suite("Migration V27: the standing-item markers (P11.6)")
struct StandingItemMigrationTests {
    @Test("V27 applies on a V26 Journal, adding both nullable marker columns")
    func v27AddsMarkerColumns() throws {
        let fixture = try AdoptionPromotionFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v26 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v26, upTo: "v26-adoption-refusal")
        let refusalColumnsBefore = try v26.read { try $0.columns(in: "refusal") }.map(\.name)
        let cardColumnsBefore = try v26.read { try $0.columns(in: "card") }.map(\.name)
        #expect(!refusalColumnsBefore.contains("standing_item_night_id"))
        #expect(!cardColumnsBefore.contains("divergence_standing_night_id"))

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v30-card-title")
        let refusalColumns = try journal.read { try $0.columns(in: "refusal") }.map(\.name)
        let cardColumns = try journal.read { try $0.columns(in: "card") }.map(\.name)
        #expect(refusalColumns.contains("standing_item_night_id"))
        #expect(cardColumns.contains("divergence_standing_night_id"))
    }
}
