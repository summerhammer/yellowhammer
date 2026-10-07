import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-predicate-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// The row ids of one fixture Feature → Cycle → Card chain.
private struct FixtureCard {
    let featureID: Int64
    let cycleID: Int64
    let cardID: Int64
}

/// Inserts a fixture Feature → Cycle → Card chain, or adds a Card to an existing Cycle when
/// `cycleID` is given. Each Card lands in its own repository, because `card` is unique on
/// (cycle_id, repository, authored_order) and these fixtures put several Cards in one Cycle.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String = "main",
    state: CardState = .todo,
    cycleID: Int64? = nil
) throws -> FixtureCard {
    try journal.write { db in
        let actualCycleID: Int64
        let featureID: Int64
        let uniqueRepo = "\(repository)-\(UUID().uuidString)"

        if let cycleID {
            actualCycleID = cycleID
            let feature: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT f.id FROM feature f JOIN cycle c ON c.feature_id = f.id WHERE c.id = ?",
                arguments: [cycleID]
            )
            guard let feature else {
                Issue.record("Could not find the Feature for Cycle \(cycleID)")
                return FixtureCard(featureID: 0, cycleID: 0, cardID: 0)
            }
            featureID = feature
        } else {
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
            )
            featureID = db.lastInsertedRowID

            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
                arguments: [featureID, JournalStore.timestamp(epoch)]
            )
            actualCycleID = db.lastInsertedRowID
        }

        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                actualCycleID, issueID, uniqueRepo, "card", 1, state.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
        return FixtureCard(featureID: featureID, cycleID: actualCycleID, cardID: db.lastInsertedRowID)
    }
}

/// Claims the Act-scoped lease so writes revalidate.
private func claimLease(_ journal: JournalStore, runID: RunID, act: Act = .author, now: Date = epoch) throws {
    guard case .claimed = try journal.claimActLease(act: act, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

// MARK: - Author Act Tests

@Test("author trigger: met when no Cards exist")
func authorMetNoCards() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("author trigger: met when all Cards are Done")
func authorMetAllDone() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .done)
    _ = try insertFixtureCard(journal, issueID: "CARD-2", state: .done)

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("author trigger: met when all Cards are in finished states (Blocked, Waiting on You, Shelved)")
func authorMetAllFinished() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .blocked)
    _ = try insertFixtureCard(journal, issueID: "CARD-2", state: .waitingOnYou)
    _ = try insertFixtureCard(journal, issueID: "CARD-3", state: .shelved)

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("author trigger: not met when a Todo Card exists")
func authorNotMetTodo() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo)

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.unfinishedCardsPresent))
}

@Test("author trigger: not met when an In Progress Card exists")
func authorNotMetInProgress() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .inProgress)

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.unfinishedCardsPresent))
}

// MARK: - Build Act Tests

@Test("build trigger: met when open Cycle has a Todo Card")
func buildMetWithTodoInCycle() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo)

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("build trigger: met when open Cycle has an In Progress Card")
func buildMetWithInProgressInCycle() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .inProgress)

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("build trigger: not met when no open Cycle exists")
func buildNotMetNoCycle() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.noFeatureInFlight))
}

@Test("build trigger: not met when open Cycle has only finished Cards")
func buildNotMetAllFinished() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .done).cycleID
    _ = try insertFixtureCard(journal, issueID: "CARD-2", state: .blocked, cycleID: cycleID)
    _ = try insertFixtureCard(journal, issueID: "CARD-3", state: .shelved, cycleID: cycleID)

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.cycleHasNoUnfinishedCards))
}

// MARK: - Land Act Tests

@Test("land trigger: met when open Cycle has only finished Cards")
func landMetAllFinished() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .done).cycleID
    _ = try insertFixtureCard(journal, issueID: "CARD-2", state: .blocked, cycleID: cycleID)

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("land trigger: met when open Cycle has only Shelved Cards (reclaimable)")
func landMetAllShelved() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .shelved)

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .met)
}

@Test("land trigger: not met when no open Cycle exists")
func landNotMetNoCycle() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.noFeatureInFlight))
}

@Test("land trigger: not met when open Cycle has an In Progress Card")
func landNotMetInProgress() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .inProgress)

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.cycleHasUnfinishedCards))
}

@Test("land trigger: not met when open Cycle has a Todo Card")
func landNotMetTodo() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo)

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.cycleHasUnfinishedCards))
}

// MARK: - Archived Cycle Tests

@Test("archived Cycle is not in flight for build")
func archivedCycleNotInFlightBuild() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo).cycleID

    // Archive the cycle
    try journal.write { db in
        try db.execute(
            sql: "UPDATE cycle SET archived_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), cycleID]
        )
    }

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.noFeatureInFlight))
}

@Test("archived Cycle is not in flight for land")
func archivedCycleNotInFlightLand() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .done).cycleID

    // Archive the cycle
    try journal.write { db in
        try db.execute(
            sql: "UPDATE cycle SET archived_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), cycleID]
        )
    }

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.noFeatureInFlight))
}

// MARK: - Already-Landed Cycle Tests (roadmap P10.1; risks OQ8, once per Cycle)

@Test("a landed Cycle is not met for land, even with only finished Cards")
func landedCycleNotMetForLand() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .done).cycleID
    let runID = RunID()
    try claimLease(journal, runID: runID, act: .land)
    try journal.markCycleLanded(cycleID: cycleID, runID: runID, now: epoch)

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.cycleAlreadyLanded))
}

@Test("a landed Cycle is not met for build, even with a Todo Card")
func landedCycleNotMetForBuild() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cycleID = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo).cycleID
    let runID = RunID()
    try claimLease(journal, runID: runID, act: .land)
    try journal.markCycleLanded(cycleID: cycleID, runID: runID, now: epoch)

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .scheduled, journal: journal)

    #expect(outcome == .notMet(.cycleAlreadyLanded))
}

// MARK: - Forced Trigger Tests

@Test("forced trigger overrides false predicate for author")
func forcedAuthorOverridesNotMet() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo)

    let outcome = try ActTriggerPredicate.evaluate(act: .author, trigger: .forced, journal: journal)

    #expect(outcome == .met)
}

@Test("forced trigger overrides false predicate for build")
func forcedBuildOverridesNotMet() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let outcome = try ActTriggerPredicate.evaluate(act: .build, trigger: .forced, journal: journal)

    #expect(outcome == .met)
}

@Test("forced trigger overrides false predicate for land")
func forcedLandOverridesNotMet() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let outcome = try ActTriggerPredicate.evaluate(act: .land, trigger: .forced, journal: journal)

    #expect(outcome == .met)
}

@Test("forcedForFeature trigger overrides false predicate for author")
func forcedForFeatureAuthorOverridesNotMet() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try insertFixtureCard(journal, issueID: "CARD-1", state: .todo)
    let featureName = try #require(FeatureName(rawValue: "MyFeature"))

    let outcome = try ActTriggerPredicate.evaluate(
        act: .author, trigger: .forcedForFeature(featureName), journal: journal
    )

    #expect(outcome == .met)
}
