import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.3: `blockedCardsLeftByClosedFeatures`, the read behind feature selection's adoption
// candidates (feature-authoring/select-the-next-feature, first story). A Cancelled Card is never
// Blocked, so it is never returned without a rule of its own; a Blocked Card in the open Cycle is not
// left behind by a *closed* Feature, so it is excluded too.

private struct AdoptionJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-adoption-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let adoptionEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@discardableResult
private func insertAdoptionFeature(
    _ journal: JournalStore, issueID: String, archived: Bool
) throws -> (featureID: Int64, cycleID: Int64) {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(adoptionEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [
                featureID, JournalStore.timestamp(adoptionEpoch),
                archived ? JournalStore.timestamp(adoptionEpoch) : nil
            ]
        )
        return (featureID, db.lastInsertedRowID)
    }
}

/// Inserts a fixture Card, choosing the next `authored_order` for `cycleID`/`repository` automatically
/// (the schema's uniqueness is per cycle and repository, not global) — mirroring
/// `insertReconcilerCard` (WorktreeReconcilerTests.swift), not visible from this test target.
@discardableResult
private func insertAdoptionCard(
    _ journal: JournalStore, cycleID: Int64, issueID: String, repository: String, state: CardState
) throws -> Int64 {
    try journal.write { db in
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(authored_order), 0) + 1 FROM card WHERE cycle_id = ? AND repository = ?",
            arguments: [cycleID, repository]
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", nextOrder, state.rawValue, 0,
                JournalStore.timestamp(adoptionEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Test("A Blocked Card left by a closed (archived) Feature's Cycle is returned")
func returnsBlockedCardFromArchivedCycle() throws {
    let fixture = try AdoptionJournalFixture()
    let journal = try fixture.open()
    let (_, cycleID) = try insertAdoptionFeature(journal, issueID: "FEAT-1", archived: true)
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
    )

    let candidates = try journal.blockedCardsLeftByClosedFeatures()

    #expect(candidates.count == 1)
    #expect(candidates[0].issueID == "BACK-1")
}

@Test("A Cancelled Card is never returned, even in an archived Cycle")
func excludesCancelledCard() throws {
    let fixture = try AdoptionJournalFixture()
    let journal = try fixture.open()
    let (_, cycleID) = try insertAdoptionFeature(journal, issueID: "FEAT-1", archived: true)
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .cancelled
    )

    let candidates = try journal.blockedCardsLeftByClosedFeatures()
    #expect(candidates.isEmpty)
}

@Test("A Done or Waiting on You Card in an archived Cycle is never returned")
func excludesDoneAndWaitingOnYou() throws {
    let fixture = try AdoptionJournalFixture()
    let journal = try fixture.open()
    let (_, cycleID) = try insertAdoptionFeature(journal, issueID: "FEAT-1", archived: true)
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
    )
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend",
        state: .waitingOnYou
    )

    let candidates = try journal.blockedCardsLeftByClosedFeatures()
    #expect(candidates.isEmpty)
}

@Test("A Blocked Card in the still-open Cycle is never returned")
func excludesBlockedCardInOpenCycle() throws {
    let fixture = try AdoptionJournalFixture()
    let journal = try fixture.open()
    let (_, cycleID) = try insertAdoptionFeature(journal, issueID: "FEAT-1", archived: false)
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
    )

    let candidates = try journal.blockedCardsLeftByClosedFeatures()
    #expect(candidates.isEmpty)
}

@Test("Candidates are ordered by repository then authored order")
func ordersByRepositoryThenAuthoredOrder() throws {
    let fixture = try AdoptionJournalFixture()
    let journal = try fixture.open()
    let (_, cycleID) = try insertAdoptionFeature(journal, issueID: "FEAT-1", archived: true)
    // Interleaved insertion order (mobile, backend, mobile, backend) so `authored_order` (auto-derived
    // per cycle/repository) still ends up 1 then 2 within each repository, and the read's own
    // `ORDER BY repository, authored_order` — not insertion order — is what the assertion below checks.
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "MOBILE-1", repository: "mobile", state: .blocked
    )
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
    )
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "MOBILE-2", repository: "mobile", state: .blocked
    )
    try insertAdoptionCard(
        journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .blocked
    )

    let candidates = try journal.blockedCardsLeftByClosedFeatures()
    #expect(candidates.map(\.issueID) == ["BACK-1", "BACK-2", "MOBILE-1", "MOBILE-2"])
}
