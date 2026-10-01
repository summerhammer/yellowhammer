import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.9: the predecessor gate's own durable state — `feature_repository` (recorded at
// selection, never derived from Cards), `feature_landing` (first-observation-wins), and
// `feature.released_at`.

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
