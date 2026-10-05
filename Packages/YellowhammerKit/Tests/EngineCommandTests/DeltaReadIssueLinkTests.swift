import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// issue #230: the Delta Read records each object's Linear identifier and board URL, the Feature and the
// Night Card included, though neither is a Card.

@Suite("Delta Read issue links")
struct DeltaReadIssueLinkTests {
    @Test("One read records key and url on a known Card, the in-flight Feature and the Night Card")
    func recordsLinksOnCardFeatureAndNightCard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1")
        let board = FakeReadingBoard([
            page(objects: [
                object("card-1", state: stateTodo),
                object("feature-of-card-1", state: stateTodo),
                object("night-1", state: stateTodo)
            ])
        ])
        let (read, runID) = try deltaRead(journal, board: board)
        let opening = try journal.openNight(
            nightStart: try #require(NightStart(rawValue: "2026-09-15")), mode: .rehearsal, act: .build,
            runID: runID, now: deltaEpoch
        )
        _ = try journal.recordNightCard(
            id: opening.night.id, issueID: "night-1", act: .build, runID: runID, now: deltaEpoch
        )

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        let card = try journal.card(id: cardID)
        #expect(card.issueKey == "ENG-card-1")
        #expect(card.issueIDForDisplay == "ENG-card-1")
        #expect(card.issueURL == "https://linear.app/x/card-1")
        let feature = try #require(try journal.inFlightFeature()?.feature)
        #expect(feature.issueKey == "ENG-feature-of-card-1")
        #expect(feature.issueIDForDisplay == "ENG-feature-of-card-1")
        #expect(feature.issueURL == "https://linear.app/x/feature-of-card-1")
        let night = try #require(try journal.night(id: opening.night.id))
        #expect(night.nightCardIssueKey == "ENG-night-1")
        #expect(night.nightCardIssueIDForDisplay == "ENG-night-1")
        #expect(night.nightCardIssueURL == "https://linear.app/x/night-1")
        // The report is unchanged: the Feature and the Night Card are still unknown objects.
        #expect(report.unknownObjects.map(\.id.rawValue) == ["feature-of-card-1", "night-1"])
    }
}
