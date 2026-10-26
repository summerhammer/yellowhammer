import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// The viewer shows the Feature and Work Card the way the Operator reads them (`YH-9`), never the Journal's
// issue id, which is a Linear UUID.

@Suite("DispatchPromptIndex resolves display text for Feature and Work Card")
struct DispatchPromptDisplayTests {
    private func read(
        _ fixture: borrowing PromptIndexFixture, _ journal: JournalStore, _ seed: SeededAttempt
    ) throws -> DispatchPromptItem {
        let index = try DispatchPromptIndex.read(
            journal: journal, store: fixture.makeStore(), projectID: fixture.projectID,
            scope: .attempt(cardID: seed.cardID, attemptID: seed.attemptID), asOf: epoch
        )
        return try #require(index.items.first)
    }

    private func capture(_ journal: JournalStore, _ seed: SeededAttempt, record: String) throws {
        _ = try journal.append(
            .promptCaptureRequested(
                recordID: record, pass: .worker, cardID: seed.cardID, issueID: "ALPHA-1",
                attemptID: seed.attemptID, round: 1, ordinal: nil
            ),
            act: .build, runID: seed.runID, now: epoch
        )
    }

    @Test("An item names its Card and Feature by display identifier")
    func resolvesDisplayText() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let seed = try fixture.seedAttempt(journal: journal)
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET issue_id_for_display = 'YH-12' WHERE id = ?", arguments: [seed.cardID])
            try db.execute(sql: "UPDATE feature SET issue_id_for_display = 'YH-9' WHERE issue_id = 'ALPHA-F'")
        }
        _ = try fixture.captureRecord(id: "rec-display", cardID: seed.cardID, attemptID: seed.attemptID)
        try capture(journal, seed, record: "rec-display")

        let item = try read(fixture, journal, seed)

        #expect(item.workCardDisplay == "YH-12")
        #expect(item.featureDisplay == "YH-9")
    }

    @Test("An id the Journal cannot name yields nil, not the id")
    func unresolvableIDsYieldNil() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let seed = try fixture.seedAttempt(journal: journal)
        // The record names a Feature the Journal has no row for, and the Card has no display identifier.
        _ = try fixture.captureRecord(id: "rec-unknown", cardID: seed.cardID, attemptID: seed.attemptID)
        try journal.write { db in
            try db.execute(sql: "DELETE FROM cycle")
            try db.execute(sql: "DELETE FROM feature")
        }
        try capture(journal, seed, record: "rec-unknown")

        let item = try read(fixture, journal, seed)

        #expect(item.featureIssueID == "ALPHA-F")
        #expect(item.featureDisplay == nil)
        #expect(item.workCardDisplay == nil)
    }
}
