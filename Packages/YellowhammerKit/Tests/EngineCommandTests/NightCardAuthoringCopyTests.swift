import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// Acceptance criteria for issue #411:
// - Night Card authoring lines render the predecessor Feature by identifier.
// - A Refusal or halt line does not contain "quiet Night".
// - No rendered board copy embeds a 36-character UUID where an identifier exists.

@Suite("Night Card authoring copy (issue #411)")
struct NightCardAuthoringCopyTests {
    private func uuidRegex() throws -> Regex<AnyRegexOutput> {
        try Regex(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
    }

    @Test("Predecessor Feature is rendered by identifier and Markdown link when recorded")
    func predecessorFeatureRenderedByIdentifierAndLink() throws {
        let pattern = try uuidRegex()
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let featureUUID = "114fe249-d329-47bf-b5f5-ad041a55cbd3"
        let displayID = "YLH-319"
        let url = "https://linear.app/team/issue/YLH-319"

        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature (issue_id, issue_id_for_display, issue_url, state, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [featureUUID, displayID, url, "selected", JournalStore.timestamp(Date())]
            )
        }

        let indeterminate = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: featureUUID, repositories: ["yellowhammer"]
        )
        let indeterminateLine = try #require(NightCardMaintenance.authoringLine(for: indeterminate, journal: journal))
        #expect(!indeterminateLine.contains(featureUUID))
        #expect(indeterminateLine.contains("[\(displayID)](\(url))"))
        #expect(indeterminateLine.contains("A quiet Night, not a failure."))

        let notLanded = JournalEvent.authoringPredecessorNotLanded(
            featureIssueID: featureUUID, repositories: ["yellowhammer"]
        )
        let notLandedLine = try #require(NightCardMaintenance.authoringLine(for: notLanded, journal: journal))
        #expect(!notLandedLine.contains(featureUUID))
        #expect(notLandedLine.contains("[\(displayID)](\(url))"))
        #expect(notLandedLine.contains("A quiet Night, not a failure."))

        let skippedInFlight = JournalEvent.authoringSkippedFeatureInFlight(
            featureIssueID: featureUUID
        )
        let skippedLine = try #require(NightCardMaintenance.authoringLine(for: skippedInFlight, journal: journal))
        #expect(!skippedLine.contains(featureUUID))
        #expect(skippedLine.contains("[\(displayID)](\(url))"))
        #expect(skippedLine.contains("A quiet Night, not a failure."))

        #expect(!indeterminateLine.contains(pattern))
        #expect(!notLandedLine.contains(pattern))
        #expect(!skippedLine.contains(pattern))
    }

    @Test("Predecessor Feature falls back to backticked identifier when URL is not recorded")
    func predecessorFeatureWithoutURL() throws {
        let pattern = try uuidRegex()
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let featureUUID = "224fe249-d329-47bf-b5f5-ad041a55cbd3"
        let displayID = "YLH-320"

        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature (issue_id, issue_id_for_display, state, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [featureUUID, displayID, "selected", JournalStore.timestamp(Date())]
            )
        }

        let event = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: featureUUID, repositories: ["yellowhammer"]
        )
        let line = try #require(NightCardMaintenance.authoringLine(for: event, journal: journal))
        #expect(!line.contains(featureUUID))
        #expect(line.contains("`\(displayID)`"))
        #expect(!line.contains(pattern))
    }

    @Test("Refusal and halt lines do not contain 'quiet Night' and name Operator turn")
    func refusalAndHaltLinesNameOperatorTurn() throws {
        let halt = JournalEvent.featureAuthoringHalted(
            name: "FEAT-1", reasonKind: "no-backward-compatible-seam", detail: "api"
        )
        let haltLine = try #require(NightCardMaintenance.authoringLine(for: halt))
        #expect(!haltLine.lowercased().contains("quiet night"))
        #expect(haltLine.contains("Waiting on You"))
        #expect(haltLine.contains("Operator"))

        let refusalOpened = JournalEvent.refusalOpened(
            feature: "FEAT-1", consecutiveRefusals: 1, uncitableClauses: "c1", reselectionDepth: 2
        )
        let refusalOpenedLine = try #require(NightCardMaintenance.authoringLine(for: refusalOpened))
        #expect(!refusalOpenedLine.lowercased().contains("quiet night"))
        #expect(refusalOpenedLine.contains("Refusal"))
        #expect(refusalOpenedLine.contains("Waiting on You"))
        #expect(refusalOpenedLine.contains("Operator"))

        let refusalRepeated = JournalEvent.refusalRepeated(
            feature: "FEAT-1", consecutiveRefusals: 2, uncitableClauses: "c1", reselectionDepth: 2
        )
        let refusalRepeatedLine = try #require(NightCardMaintenance.authoringLine(for: refusalRepeated))
        #expect(!refusalRepeatedLine.lowercased().contains("quiet night"))
        #expect(refusalRepeatedLine.contains("Refusal"))
        #expect(refusalRepeatedLine.contains("Waiting on You"))
        #expect(refusalRepeatedLine.contains("Operator"))
    }

    @Test("Genuine skips keep 'A quiet Night, not a failure.'")
    func genuineSkipsKeepQuietNight() throws {
        let noWork = JournalEvent.authoringNoWorkAvailable
        let noWorkLine = try #require(NightCardMaintenance.authoringLine(for: noWork))
        #expect(noWorkLine.contains("A quiet Night, not a failure."))

        let inFlight = JournalEvent.authoringSkippedFeatureInFlight(featureIssueID: "FEAT-1")
        let inFlightLine = try #require(NightCardMaintenance.authoringLine(for: inFlight))
        #expect(inFlightLine.contains("A quiet Night, not a failure."))

        let notLanded = JournalEvent.authoringPredecessorNotLanded(
            featureIssueID: "FEAT-1", repositories: ["backend"]
        )
        let notLandedLine = try #require(NightCardMaintenance.authoringLine(for: notLanded))
        #expect(notLandedLine.contains("A quiet Night, not a failure."))

        let indeterminate = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: "FEAT-1", repositories: ["backend"]
        )
        let indeterminateLine = try #require(NightCardMaintenance.authoringLine(for: indeterminate))
        #expect(indeterminateLine.contains("A quiet Night, not a failure."))
    }
}
