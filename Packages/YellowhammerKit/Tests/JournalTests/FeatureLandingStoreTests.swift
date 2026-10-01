import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.9: the predecessor gate's own durable state — `feature_repository` (recorded at
// selection, never derived from Cards), `feature_landing` (first-observation-wins), and
// `feature.released_at`. Migration v18 backfills `feature_repository` for every pre-v18 Feature from
// its Cards, the best evidence a pre-v18 Journal has.

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

private func insertFixtureFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Feature landing store (P9.9)")
struct FeatureLandingStoreTests {
    @Test("Migration v18 applies on a v17 Journal, adding the new tables and column")
    func migrationV18AppliesOnV17Database() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v17 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v17, upTo: "v17-authoring-halt")
        #expect(try !v17.read { try $0.tableExists("feature_repository") })
        #expect(try !v17.read { try $0.tableExists("feature_landing") })

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v31-operator-abort-request")
        #expect(try journal.tableNames().contains("feature_repository"))
        #expect(try journal.tableNames().contains("feature_landing"))
        let featureColumns = try journal.read { try $0.columns(in: "feature") }.map(\.name)
        #expect(featureColumns.contains("released_at"))
    }

    @Test("Migration v18 backfills feature_repository from a pre-v18 Journal's Cards")
    func migrationV18BackfillsFromCards() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v17 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v17, upTo: "v17-authoring-halt")
        try v17.writeWithoutTransaction { db in
            try db.execute(
                sql: "INSERT INTO feature (id, issue_id, state, created_at) VALUES (1, 'FEAT-BACKFILL', 'selected', ?)",
                arguments: [JournalStore.timestamp(epoch)]
            )
            try db.execute(
                sql: "INSERT INTO cycle (id, feature_id, created_at, archived_at) VALUES (1, 1, ?, ?)",
                arguments: [JournalStore.timestamp(epoch), JournalStore.timestamp(epoch)]
            )
            let cards = [
                ("BACK-1", "backend", 1), ("MOB-1", "mobile", 1), ("BACK-2", "backend", 2)
            ]
            for (issueID, repository, order) in cards {
                try db.execute(
                    sql: """
                    INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, created_at)
                    VALUES (1, ?, ?, 'card', ?, 'todo', ?)
                    """,
                    arguments: [issueID, repository, order, JournalStore.timestamp(epoch)]
                )
            }
        }

        let journal = try fixture.open()

        let touched = try journal.touchedRepositories(featureID: 1)
        #expect(touched == ["backend", "mobile"])
    }

    @Test("touchedRepositories reads feature_repository, never Cards")
    func touchedRepositoriesReadsItsOwnTable() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, "backend"]
            )
        }

        #expect(try journal.touchedRepositories(featureID: featureID) == ["backend"])
    }

    @Test("recordLanding is first-observation-wins, and landings reads every recorded repository")
    func recordLandingFirstObservationWins() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let first = try journal.recordLanding(featureID: featureID, repository: "backend", mainlineCommit: "aaa")
        let second = try journal.recordLanding(featureID: featureID, repository: "backend", mainlineCommit: "bbb")
        _ = try journal.recordLanding(featureID: featureID, repository: "mobile", mainlineCommit: "ccc")

        #expect(first)
        #expect(!second)
        let landings = try journal.landings(featureID: featureID)
        #expect(landings["backend"] == "aaa")
        #expect(landings["mobile"] == "ccc")
    }

    @Test("markFeatureReleased sets released_at; a second Feature is untouched")
    func markFeatureReleasedSetsReleasedAt() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let otherID = try insertFixtureFeature(journal, issueID: "FEAT-2")

        try journal.markFeatureReleased(featureID: featureID, now: epoch)

        let walk = try journal.predecessorFeature()
        _ = walk
        let releasedAt: String? = try journal.read { db in
            try String.fetchOne(db, sql: "SELECT released_at FROM feature WHERE id = ?", arguments: [featureID])
        }
        let otherReleasedAt: String? = try journal.read { db in
            try String.fetchOne(db, sql: "SELECT released_at FROM feature WHERE id = ?", arguments: [otherID])
        }
        #expect(releasedAt != nil)
        #expect(otherReleasedAt == nil)
    }

    @Test("markFeatureReleased on an unknown Feature throws")
    func markFeatureReleasedUnknownThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(throws: JournalError.self) {
            try journal.markFeatureReleased(featureID: 999, now: epoch)
        }
    }
}
