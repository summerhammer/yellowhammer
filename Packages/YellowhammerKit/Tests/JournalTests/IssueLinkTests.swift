import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// issue #230: the Journal records each Linear issue's identifier and board URL, so the Pulse can open
// them as they are.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-issue-link-\(UUID().uuidString)", directoryHint: .isDirectory)
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
private let nightStart = NightStart(rawValue: "2026-09-15")!  // swiftlint:disable:this force_unwrapping

private func record(
    _ journal: JournalStore, _ issueID: String, _ key: String, _ url: String, runID: RunID
) throws -> Bool {
    try journal.recordIssueLink(issueID: issueID, key: key, url: url, runID: runID, now: epoch)
}

private func insertCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, issueID, "main", "card", 1, CardState.todo.rawValue, 0, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Issue links (issue #230)")
struct IssueLinkTests {
    @Test("A Card, a Feature and a Night Card each take the key and url recorded for their issue id")
    func updatesCardFeatureAndNightCard() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1")
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
        _ = try journal.recordNightCard(
            id: opening.night.id, issueID: "night-1", act: .author, runID: run, now: epoch
        )

        #expect(try journal.card(id: cardID).issueKey == nil)
        #expect(try record(journal, "card-1", "YH-1", "https://l/1", runID: run))
        #expect(
            try record(journal, "feature-of-card-1", "YH-2", "https://l/2", runID: run)
        )
        #expect(try record(journal, "night-1", "YH-3", "https://l/3", runID: run))

        let card = try journal.card(id: cardID)
        #expect(card.issueKey == "YH-1")
        #expect(card.issueURL == "https://l/1")
        let feature = try #require(try journal.inFlightFeature()?.feature)
        #expect(feature.issueKey == "YH-2")
        #expect(feature.issueURL == "https://l/2")
        let night = try #require(try journal.night(id: opening.night.id))
        #expect(night.nightCardIssueKey == "YH-3")
        #expect(night.nightCardIssueURL == "https://l/3")
        // No event: a link is not loop state.
        #expect(try journal.events().map(\.type) == [.nightOpened, .nightCardOpened])
    }

    @Test("A repeat with the same values, and an unknown issue id, change nothing")
    func repeatAndUnknownAreNoOps() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        _ = try insertCard(journal, issueID: "card-1")
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

        #expect(try record(journal, "card-1", "YH-1", "https://l/1", runID: run))
        #expect(try !record(journal, "card-1", "YH-1", "https://l/1", runID: run))
        #expect(try !record(journal, "nope", "YH-9", "https://l/9", runID: run))
    }

    @Test("A changed url, or a changed key, is a change")
    func changedValuesChange() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1")
        let run = RunID()
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        _ = try record(journal, "card-1", "YH-1", "https://l/1", runID: run)

        #expect(try record(journal, "card-1", "YH-1", "https://l/moved", runID: run))
        #expect(try journal.card(id: cardID).issueURL == "https://l/moved")
        #expect(try record(journal, "card-1", "YH-7", "https://l/moved", runID: run))
        #expect(try journal.card(id: cardID).issueKey == "YH-7")
    }

    @Test("Recording a link needs the Act-scoped lease")
    func needsTheLease() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        _ = try insertCard(journal, issueID: "card-1")

        #expect(throws: (any Error).self) {
            try record(journal, "card-1", "YH-1", "https://l/1", runID: RunID())
        }
    }
}
