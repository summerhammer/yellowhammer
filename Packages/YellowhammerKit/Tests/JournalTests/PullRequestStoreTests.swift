import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.4: the `pull_request` table records a Repo Lane's opened pull request once, unique on
// (feature_id, repository) so a first write wins and the seam above it never updates or duplicates.

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

private func insertFixtureNight(_ journal: JournalStore, projectID: ProjectID) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO night (project_id, night_start, mode, state, opened_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [projectID.rawValue, "2026-09-16", "real", "open", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@Suite("Pull request store (P10.4)")
struct PullRequestStoreTests {
    @Test("Migration v19 applies on a v18 Journal, adding the pull_request table")
    func migrationV19AppliesOnV18Database() throws {
        let fixture = try JournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let v18 = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(v18, upTo: "v18-predecessor-gate")
        #expect(try !v18.read { try $0.tableExists("pull_request") })

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v24-card-reply")
        let exists = try journal.write { db in try db.tableExists("pull_request") }
        #expect(exists)
    }

    @Test("First recordPullRequest wins; a second call for the same feature/repository inserts nothing")
    func firstWriteWins() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))
        let runID = RunID()

        let firstInserted = try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: runID, now: epoch
        )
        #expect(firstInserted)

        let secondInserted = try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/2",
            nightID: nightID, runID: runID, now: epoch
        )
        #expect(!secondInserted)

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "backend"))
        #expect(record.url == "https://github.com/o/r/pull/1")
    }

    @Test("alreadyOpen records with a nil URL")
    func recordsNilURLForAlreadyOpen() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))

        try journal.recordPullRequest(
            featureID: featureID, repository: "mobile", url: nil, nightID: nightID, runID: RunID(), now: epoch
        )

        let record = try #require(try journal.pullRequest(featureID: featureID, repository: "mobile"))
        #expect(record.url == nil)
    }

    @Test("pullRequests(featureID:) returns every recorded repository")
    func returnsAllRepositories() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let nightID = try insertFixtureNight(journal, projectID: try #require(ProjectID(rawValue: "fixture")))

        try journal.recordPullRequest(
            featureID: featureID, repository: "backend", url: "https://github.com/o/r/pull/1",
            nightID: nightID, runID: RunID(), now: epoch
        )
        try journal.recordPullRequest(
            featureID: featureID, repository: "mobile", url: nil, nightID: nightID, runID: RunID(), now: epoch
        )

        let all = try journal.pullRequests(featureID: featureID)
        #expect(all.count == 2)
        #expect(all["backend"]?.url == "https://github.com/o/r/pull/1")
        #expect(all["mobile"]?.url == nil)
    }
}
