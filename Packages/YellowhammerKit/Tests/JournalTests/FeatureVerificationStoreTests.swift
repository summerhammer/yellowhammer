import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.5: the `feature_verification` and `clause_verification` tables record a Cycle's Verification
// once (first write wins), snapshotting each clause as it was judged; the `featureVerified` event carries
// counts only.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
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
private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!

private struct World {
    let featureID: Int64
    let cycleID: Int64
    let nightID: Int64
}

private func makeWorld(_ journal: JournalStore, projectID: ProjectID) throws -> World {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [projectID.rawValue, "2026-09-16", "real", "open", JournalStore.timestamp(epoch)]
        )
        return World(featureID: featureID, cycleID: cycleID, nightID: db.lastInsertedRowID)
    }
}

private func insertCard(_ journal: JournalStore, cycleID: Int64, issueID: String, order: Int) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, 'backend', 'card', ?, 'Done', 0, ?)
            """,
            arguments: [cycleID, issueID, order, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func insertAttempt(_ journal: JournalStore, cardID: Int64, route: Route) throws {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO attempt (card_id, budget_epoch, route_cli, route_model, route_effort, started_at)
            VALUES (?, 0, ?, ?, ?, ?)
            """,
            arguments: [cardID, route.cli, route.model, route.effort, JournalStore.timestamp(epoch)]
        )
    }
}

private func record(
    _ cid: String, issue: String = "BACK-1", verdict: ClauseVerdict = .met, judgedBy: ClauseJudge = .agent,
    provenance: String = "machine-found", invalidatedCause: String? = nil
) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: issue, cid: cid, level: "card", text: "Clause \(cid).", locationID: "epic/story",
        citationProvenance: provenance, verdict: verdict, whatWasChecked: "checked \(cid)",
        interpretation: "read \(cid)", judgedBy: judgedBy, invalidatedCause: invalidatedCause
    )
}

@Suite("Feature verification store (P10.5)")
struct FeatureVerificationStoreTests {
    @Test("Migration v20 applies on a v19 Journal, adding both verification tables")
    func migrationV20AppliesOnV19Database() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v19 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v19, upTo: "v19-pull-request")
        #expect(try !v19.read { try $0.tableExists("feature_verification") })
        #expect(try !v19.read { try $0.tableExists("clause_verification") })

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v20-feature-verification")
        let tables = try journal.tableNames()
        #expect(tables.contains("feature_verification"))
        #expect(tables.contains("clause_verification"))
    }

    @Test("A recorded Verification reads back with its clauses in the order given, snapshots intact")
    func roundTrip() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        let clauses = [
            record("c2", issue: "FEAT-1", provenance: "Author-supplied"),
            record("c1", verdict: .unmet, judgedBy: .engine, invalidatedCause: "text_edited"),
            record("c3", verdict: .unresolved, judgedBy: .engine)
        ]
        let runID = RunID()

        let inserted = try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: world.featureID, cycleID: world.cycleID, route: routeB.description, nightID: world.nightID,
            runID: runID, clauses: clauses
        ), now: epoch)

        #expect(inserted)
        let read = try #require(try journal.featureVerification(cycleID: world.cycleID))
        #expect(read.clauses == clauses)
        #expect(read.route == routeB.description)
        #expect(read.runID == runID)
        #expect(read.nightID == world.nightID)
        #expect(read.verifiedAt == epoch)
        #expect(try journal.featureVerification(cycleID: world.cycleID + 1) == nil)
    }

    @Test("First write wins per Cycle: a second record inserts nothing and changes nothing")
    func firstWriteWins() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: world.featureID, cycleID: world.cycleID, route: nil, nightID: world.nightID,
            runID: RunID(), clauses: [record("c1")]
        ), now: epoch)

        let second = try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: world.featureID, cycleID: world.cycleID, route: routeA.description, nightID: world.nightID,
            runID: RunID(), clauses: [record("c1", verdict: .unmet), record("c2")]
        ), now: epoch)

        #expect(!second)
        let read = try #require(try journal.featureVerification(cycleID: world.cycleID))
        #expect(read.route == nil)
        #expect(read.clauses == [record("c1")])
    }

    @Test("The verdict and judge are constrained by the schema")
    func schemaRejectsUnknownVerdict() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: world.featureID, cycleID: world.cycleID, route: nil, nightID: world.nightID,
            runID: RunID(), clauses: [record("c1")]
        ), now: epoch)
        #expect(throws: (any Error).self) {
            try journal.write { db in
                try db.execute(sql: "UPDATE clause_verification SET verdict = 'passed'")
            }
        }
        #expect(throws: (any Error).self) {
            try journal.write { db in
                try db.execute(sql: "UPDATE clause_verification SET judged_by = 'model'")
            }
        }
    }

    @Test("attemptRoutes lists each distinct Route the Cycle's Attempts ran on, in first-use order")
    func attemptRoutesAreDistinct() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let world = try makeWorld(journal, projectID: fixture.projectID)
        let first = try insertCard(journal, cycleID: world.cycleID, issueID: "BACK-1", order: 1)
        let second = try insertCard(journal, cycleID: world.cycleID, issueID: "BACK-2", order: 2)
        try insertAttempt(journal, cardID: first, route: routeB)
        try insertAttempt(journal, cardID: second, route: routeA)
        try insertAttempt(journal, cardID: second, route: routeB)

        #expect(try journal.attemptRoutes(cycleID: world.cycleID) == [routeB, routeA])
        #expect(try journal.attemptRoutes(cycleID: world.cycleID + 1).isEmpty)
    }

    @Test("featureVerified round-trips with counts only")
    func eventRoundTrips() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let run = RunID()

        try journal.append(
            .featureVerified(cycleID: 7, met: 3, unmet: 2, unresolved: 1), act: .land, runID: run, now: epoch
        )

        let records = try journal.events(ofType: .featureVerified)
        #expect(records.map(\.event) == [.featureVerified(cycleID: 7, met: 3, unmet: 2, unresolved: 1)])
        #expect(JournalEventType.featureVerified.rawValue == "FeatureVerified")
    }
}
