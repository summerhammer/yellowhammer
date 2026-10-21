import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.9: the predecessor gate's own durable state — `feature_repository` (recorded at
// selection, never derived from Cards), `feature_landing` (first-observation-wins), and
// `feature.abandoned_at`.

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

        let first = try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "aaa", evidence: .ancestry
        )
        let second = try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "bbb", evidence: .ancestry
        )
        _ = try journal.recordLanding(
            featureID: featureID, repository: "mobile", mainlineCommit: "ccc", evidence: .ancestry
        )

        #expect(first)
        #expect(!second)
        let landings = try journal.landings(featureID: featureID)
        #expect(landings["backend"] == "aaa")
        #expect(landings["mobile"] == "ccc")
    }

    @Test("recordLanding keeps the evidence of the first observation, and landingEvidence reads each repository")
    func recordLandingKeepsTheFirstEvidence() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "aaa", evidence: .content
        )
        let overwritten = try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "bbb", evidence: .ancestry
        )
        try journal.recordLanding(
            featureID: featureID, repository: "mobile", mainlineCommit: "ccc", evidence: .ancestry
        )

        #expect(!overwritten)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content, "mobile": .ancestry])
        // Callers that need only the repository set are unaffected by the evidence.
        #expect(try journal.landings(featureID: featureID) == ["backend": "aaa", "mobile": "ccc"])
    }

    @Test("A landing whose evidence is neither ancestry nor content is unreadable")
    func unknownEvidenceIsUnreadable() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature_landing (feature_id, repository, mainline_commit, observed_at, evidence)
                VALUES (?, 'backend', 'aaa', ?, 'guess')
                """,
                arguments: [featureID, JournalStore.timestamp(epoch)]
            )
        }

        #expect(throws: JournalError.landingEvidenceUnreadable(featureID: featureID, repository: "backend")) {
            _ = try journal.landingEvidence(featureID: featureID)
        }
    }

    @Test("markFeatureAbandoned sets abandoned_at; a second Feature is untouched")
    func markFeatureAbandonedSetsAbandonedAt() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let otherID = try insertFixtureFeature(journal, issueID: "FEAT-2")

        try journal.markFeatureAbandoned(featureID: featureID, now: epoch)

        let abandonedAt: String? = try journal.read { db in
            try String.fetchOne(db, sql: "SELECT abandoned_at FROM feature WHERE id = ?", arguments: [featureID])
        }
        let otherAbandonedAt: String? = try journal.read { db in
            try String.fetchOne(db, sql: "SELECT abandoned_at FROM feature WHERE id = ?", arguments: [otherID])
        }
        #expect(abandonedAt != nil)
        #expect(otherAbandonedAt == nil)
    }

    @Test("markFeatureAbandoned on an unknown Feature throws")
    func markFeatureAbandonedUnknownThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(throws: JournalError.self) {
            try journal.markFeatureAbandoned(featureID: 999, now: epoch)
        }
    }
}
