import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// issue #556: `selectionBoardState`, the Journal read behind the selection pass's `## Board state`
// section. A Feature's name lives only in its `FeatureAuthored` event, so the read joins on the issue id.

private struct BoardStateJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-board-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let boardStateEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@discardableResult
private func insertFeature(
    _ journal: JournalStore, issueID: String, key: String?, state: String = "selected", ageDays: Int = 0,
    closedBy: String? = nil, abandoned: Bool = false
) throws -> Int64 {
    try journal.write { db in
        let created = boardStateEpoch.addingTimeInterval(Double(ageDays) * 86_400)
        try db.execute(
            sql: """
            INSERT INTO feature (issue_id, issue_key, state, created_at, closed_by, abandoned_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                issueID, key, state, JournalStore.timestamp(created), closedBy,
                abandoned ? JournalStore.timestamp(created) : nil
            ]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(created)]
        )
        return db.lastInsertedRowID
    }
}

private struct CardFixture {
    var issueID: String
    var key: String?
    var title: String?
    var repository: String
    var order: Int
    var state: CardState
    var reason: WaitingReason?
    var removed = false
}

private func insertCard(_ journal: JournalStore, cycleID: Int64, _ card: CardFixture) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, issue_key, title, repository, kind, authored_order, state,
                              waiting_reason, removed_from_board, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, 'card', ?, ?, ?, ?, 0, ?)
            """,
            arguments: [
                cycleID, card.issueID, card.key, card.title, card.repository, card.order, card.state.rawValue,
                card.reason?.rawValue, card.removed ? "trashed" : nil, JournalStore.timestamp(boardStateEpoch)
            ]
        )
    }
}

@Test("An empty Journal has no board state")
func emptyJournal() throws {
    let fixture = try BoardStateJournalFixture()
    let journal = try fixture.open()
    #expect(try journal.selectionBoardState().isEmpty)
}

@Test("Features come newest first with names from FeatureAuthored events, identifiers, and outcomes")
func featuresNamesIdentifiersOutcomes() throws {
    let fixture = try BoardStateJournalFixture()
    let journal = try fixture.open()
    try insertFeature(journal, issueID: "uuid-landed", key: "YLH-1", ageDays: 0, closedBy: "verification")
    try insertFeature(journal, issueID: "uuid-abandoned", key: "YLH-2", ageDays: 1, abandoned: true)
    try insertFeature(journal, issueID: "uuid-open", key: "YLH-3", state: "in_progress", ageDays: 2)
    try insertFeature(journal, issueID: "uuid-nameless", key: nil, ageDays: 3)
    for (issueID, name) in [("uuid-landed", "First"), ("uuid-abandoned", "Second"), ("uuid-open", "Third")] {
        try journal.append(.featureAuthored(FeatureAuthoredPayload(
            name: name, groupKey: "g-\(name)", featureIssueID: issueID, cycleID: 1, cardCount: 1, adoptedCount: 0
        )))
    }

    let features = try journal.selectionBoardState().features

    #expect(features == [
        .init(name: nil, identifier: "no board identifier yet", outcome: "selected"),
        .init(name: "Third", identifier: "YLH-3", outcome: "in_progress"),
        .init(name: "Second", identifier: "YLH-2", outcome: "abandoned"),
        .init(name: "First", identifier: "YLH-1", outcome: "landed")
    ])
    #expect(!features.contains { $0.identifier.hasPrefix("uuid") })
}

@Test("At most twenty Features are returned")
func featureCap() throws {
    let fixture = try BoardStateJournalFixture()
    let journal = try fixture.open()
    for index in 0..<25 {
        try insertFeature(journal, issueID: "uuid-\(index)", key: "YLH-\(index)", ageDays: index)
    }
    let features = try journal.selectionBoardState().features
    #expect(features.count == 20)
    #expect(features.first?.identifier == "YLH-24")
}

@Test("Waiting on You Cards across Cycles are returned by repository then order, without removed Cards")
func waitingOnYouCards() throws {
    let fixture = try BoardStateJournalFixture()
    let journal = try fixture.open()
    let cycleA = try insertFeature(journal, issueID: "uuid-a", key: "YLH-1")
    let cycleB = try insertFeature(journal, issueID: "uuid-b", key: "YLH-2", ageDays: 1, closedBy: "merge")
    try insertCard(journal, cycleID: cycleA, CardFixture(
        issueID: "c-2", key: "YLH-12", title: "Second", repository: "web", order: 1,
        state: .waitingOnYou, reason: .overreach
    ))
    try insertCard(journal, cycleID: cycleB, CardFixture(
        issueID: "c-1", key: "YLH-11", title: "First", repository: "backend", order: 1,
        state: .waitingOnYou, reason: .question
    ))
    try insertCard(journal, cycleID: cycleB, CardFixture(
        issueID: "c-3", key: nil, title: nil, repository: "backend", order: 2, state: .waitingOnYou, removed: true
    ))
    try insertCard(journal, cycleID: cycleA, CardFixture(
        issueID: "c-4", key: "YLH-14", title: "Blocked", repository: "backend", order: 3, state: .blocked
    ))

    let waiting = try journal.selectionBoardState().waitingCards

    #expect(waiting == [
        .init(identifier: "YLH-11", title: "First", repository: "backend", reason: "question"),
        .init(identifier: "YLH-12", title: "Second", repository: "web", reason: "overreach")
    ])
}

private func seedUnmergedFeature(
    _ journal: JournalStore, issueID: String, key: String, name: String, landed: Bool = false
) throws {
    try journal.write { db in
        let stamp = JournalStore.timestamp(boardStateEpoch)
        try db.execute(
            sql: """
            INSERT INTO feature (issue_id, issue_key, state, created_at, closed_by)
            VALUES (?, ?, 'closed', ?, 'verification')
            """,
            arguments: [issueID, key, stamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at, landed_at) VALUES (?, ?, ?, ?)",
            arguments: [featureID, stamp, stamp, stamp]
        )
        try db.execute(
            sql: """
            INSERT INTO feature_repository (feature_id, repository, branch, landed_commit)
            VALUES (?, 'repo-a', ?, 'c1')
            """,
            arguments: [featureID, "yh-\(issueID)"]
        )
    }
    if landed {
        let featureID = try #require(try journal.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM feature WHERE issue_id = ?", arguments: [issueID])
        })
        try journal.recordLanding(
            featureID: featureID, repository: "repo-a", mainlineCommit: "main-a", evidence: .ancestry
        )
    }
    try journal.append(.featureAuthored(FeatureAuthoredPayload(
        name: name, groupKey: "g-\(issueID)", featureIssueID: issueID, cycleID: 1, cardCount: 1, adoptedCount: 0
    )))
}

@Suite("Board state: Unmerged Feature Stack (P23.2)")
struct SelectionBoardStateUnmergedTests {
    @Test("A Feature in U is listed with its name, identifier, touched repositories and unmerged branches")
    func unmergedFeatureIsListed() throws {
        let fixture = try BoardStateJournalFixture()
        let journal = try fixture.open()
        try seedUnmergedFeature(journal, issueID: "f1", key: "YLH-1", name: "Add login")

        let state = try journal.selectionBoardState()

        #expect(state.unmergedFeatures == [
            .init(
                name: "Add login", identifier: "YLH-1", touchedRepositories: ["repo-a"],
                unmergedBranches: [.init(repository: "repo-a", branch: "yh-f1")]
            )
        ])
        #expect(!state.isEmpty)
        #expect(state.unmergedFeature(named: "  add LOGIN ")?.identifier == "YLH-1")
        #expect(state.unmergedFeature(named: "other") == nil)
    }

    @Test("A fully merged Feature is not listed")
    func mergedFeatureIsNotListed() throws {
        let fixture = try BoardStateJournalFixture()
        let journal = try fixture.open()
        try seedUnmergedFeature(journal, issueID: "f1", key: "YLH-1", name: "Add login", landed: true)

        #expect(try journal.selectionBoardState().unmergedFeatures.isEmpty)
    }
}
