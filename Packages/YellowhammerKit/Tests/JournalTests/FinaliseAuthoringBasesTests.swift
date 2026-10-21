import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P23.2 (spec: feature-authoring/select-the-next-feature `#effective-base`): `finaliseAuthoring`
// records the plan's bases in the same transaction as the Feature, for the repositories the plan touches.

private struct FinaliseJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-finalise-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let finaliseEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("finaliseAuthoring records feature_base (P23.2)")
struct FinaliseAuthoringBasesTests {
    @Test("Bases for the plan's repositories are written, and a base for an untouched repository is not")
    func writesBasesForTouchedRepositories() throws {
        let fixture = try FinaliseJournalFixture()
        let journal = try fixture.open()
        let run = RunID()
        guard case .claimed = try journal.claimActLease(
            act: .author, runID: run, mode: .rehearsal, now: finaliseEpoch
        ) else {
            Issue.record("could not claim the Act Lease")
            return
        }
        // `stacked_on_feature_id` is a foreign key: the Feature the base stacks on must exist.
        let stackedOn = try journal.write { db in
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES ('issue-0', 'closed', ?)",
                arguments: [JournalStore.timestamp(finaliseEpoch)]
            )
            return db.lastInsertedRowID
        }
        let nightID = try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    fixture.projectID.rawValue, "2026-09-16", "real", "open", JournalStore.timestamp(finaliseEpoch)
                ]
            )
            return db.lastInsertedRowID
        }
        let repoA = FeatureBaseRecord(
            repository: "repo-a", baseRef: "refs/yellowhammer/landed/yh-f1", baseCommit: "c1",
            stackedOnFeatureID: stackedOn
        )
        let repoB = FeatureBaseRecord(repository: "repo-b", baseRef: "refs/remotes/origin/main", baseCommit: "m2")
        let repoC = FeatureBaseRecord(repository: "repo-c", baseRef: "refs/remotes/origin/main", baseCommit: "m3")
        let plan = FeatureAuthoringAcceptedPayload(
            name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureKey: "feature:FEAT-1:0:create", nightID: nightID,
            cards: [], adoptions: [], repositories: ["repo-a", "repo-b"], bases: [repoA, repoB, repoC]
        )

        let cycleID = try journal.finaliseAuthoring(
            AuthoredFeature(plan: plan, featureIssueID: "issue-1", cards: []),
            runID: run, act: .author, nightID: nightID, now: finaliseEpoch
        )

        #expect(cycleID != nil)
        let featureID = try journal.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM feature WHERE issue_id = ?", arguments: ["issue-1"])
        }
        #expect(try journal.featureBases(featureID: try #require(featureID)) == [repoA, repoB])
    }
}
