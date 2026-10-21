import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P23.1 (spec: feature-authoring/select-the-next-feature `#unmerged-feature-stack`,
// `#effective-base`): U is read from the Journal alone, and `feature_base` records the base each Feature
// was authored against.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Seeds a Feature with a Cycle and `feature_repository` rows (`pushing`, each with a branch and a landed
/// commit). `archived` archives the Cycle, `closedBy` sets the closure, `cycleLanded` sets `landed_at`.
@discardableResult
private func seedFeature(
    _ journal: JournalStore, issueID: String, pushing repositories: [String], archived: Bool = true,
    closedBy: String? = "verification", cycleLanded: Bool = true, abandoned: Bool = false
) throws -> Int64 {
    try journal.write { db in
        let stamp = JournalStore.timestamp(epoch)
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at, closed_by, abandoned_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [issueID, archived ? "closed" : "selected", stamp, archived ? closedBy : nil,
                        abandoned ? stamp : nil]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at, landed_at) VALUES (?, ?, ?, ?)",
            arguments: [featureID, stamp, archived ? stamp : nil, cycleLanded ? stamp : nil]
        )
        for repository in repositories {
            try db.execute(
                sql: """
                INSERT INTO feature_repository (feature_id, repository, branch, landed_commit) VALUES (?, ?, ?, ?)
                """,
                arguments: [featureID, repository, "yh/\(issueID.lowercased())", "commit-\(issueID)-\(repository)"]
            )
        }
        return featureID
    }
}

private func land(_ journal: JournalStore, _ featureID: Int64, _ repository: String) throws {
    try journal.recordLanding(
        featureID: featureID, repository: repository, mainlineCommit: "main-\(repository)", evidence: .ancestry
    )
}

@Suite("Unmerged Feature Stack (P23.1)")
struct UnmergedFeatureStackTests {
    @Test("An empty Journal has an empty stack and a mainline base")
    func emptyJournal() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        #expect(try journal.unmergedFeatureStack().isEmpty)
        #expect(try journal.effectiveBase(repository: "backend") == nil)
    }

    @Test("An archived, verified Feature with a pushed repository and no landing is in U")
    func unmergedFeatureIsInStack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let id = try seedFeature(journal, issueID: "F-1", pushing: ["backend"])

        let stack = try journal.unmergedFeatureStack()
        #expect(stack.map(\.feature.id) == [id])
        let member = try #require(stack.first)
        #expect(member.touchedRepositories == ["backend"])
        #expect(member.pushedRepositories == ["backend"])
        #expect(member.branches == ["backend": "yh/f-1"])
        #expect(member.landedCommits == ["backend": "commit-F-1-backend"])
        #expect(member.mergedRepositories.isEmpty)
        #expect(member.unmergedRepositories == ["backend"])
    }

    @Test("A Feature whose every pushed repository has a landing is not in U")
    func fullyMergedFeatureIsNotInStack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let id = try seedFeature(journal, issueID: "F-1", pushing: ["backend"])
        try land(journal, id, "backend")
        #expect(try journal.unmergedFeatureStack().isEmpty)
    }

    @Test("A Feature merged in k of N repositories stays in U with the split")
    func partiallyMergedFeatureStaysInStack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let id = try seedFeature(journal, issueID: "F-1", pushing: ["backend", "mobile"])
        try land(journal, id, "mobile")

        let member = try #require(try journal.unmergedFeatureStack().first)
        #expect(member.pushedRepositories == ["backend", "mobile"])
        #expect(member.mergedRepositories == ["mobile"])
        #expect(member.unmergedRepositories == ["backend"])
    }

    @Test("An abandoned Feature, an in-flight Feature and a merge-closed Feature are excluded")
    func exclusions() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, issueID: "ABANDONED", pushing: ["backend"], abandoned: true)
        try seedFeature(journal, issueID: "INFLIGHT", pushing: ["backend"], archived: false)
        let merged = try seedFeature(journal, issueID: "MERGED", pushing: ["backend"], closedBy: "merge")
        try land(journal, merged, "backend")
        #expect(try journal.unmergedFeatureStack().isEmpty)
    }

    @Test("A completion-closed Feature whose Cycle never landed has N = 0 and is excluded")
    func completionClosedWithoutLandingIsExcluded() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        try seedFeature(journal, issueID: "F-1", pushing: ["backend"], closedBy: "completion", cycleLanded: false)
        #expect(try journal.unmergedFeatureStack().isEmpty)
    }

    @Test("A completion-closed Feature whose Cycle landed is in U")
    func completionClosedAfterLandingIsInStack() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let id = try seedFeature(journal, issueID: "F-1", pushing: ["backend"], closedBy: "completion")
        #expect(try journal.unmergedFeatureStack().map(\.feature.id) == [id])
    }

    @Test("U is ordered by Feature id")
    func orderedByFeatureID() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let first = try seedFeature(journal, issueID: "F-1", pushing: ["backend"])
        let second = try seedFeature(journal, issueID: "F-2", pushing: ["mobile"])
        let third = try seedFeature(journal, issueID: "F-3", pushing: ["backend"])
        #expect(try journal.unmergedFeatureStack().map(\.feature.id) == [first, second, third])
    }

    @Test("effectiveBase is the most recent pusher per repository, and honours excludingFeatureID")
    func effectiveBasePicksMostRecentPusher() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let first = try seedFeature(journal, issueID: "F-1", pushing: ["backend", "mobile"])
        let second = try seedFeature(journal, issueID: "F-2", pushing: ["backend"])

        let backend = try #require(try journal.effectiveBase(repository: "backend"))
        #expect(backend.featureID == second)
        #expect(backend.featureIssueID == "F-2")
        #expect(backend.branch == "yh/f-2")
        #expect(backend.landedCommit == "commit-F-2-backend")
        #expect(try journal.effectiveBase(repository: "mobile")?.featureID == first)
        #expect(try journal.effectiveBase(repository: "web") == nil)
        #expect(try journal.effectiveBase(repository: "backend", excludingFeatureID: second)?.featureID == first)

        try land(journal, second, "backend")
        #expect(try journal.effectiveBase(repository: "backend")?.featureID == first)
    }

    @Test("recordFeatureBases round-trips sorted by repository and replaces on repeat")
    func featureBasesRoundTripAndReplace() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let first = try seedFeature(journal, issueID: "F-1", pushing: ["backend"])
        let second = try seedFeature(journal, issueID: "F-2", pushing: [], archived: false)

        #expect(try journal.featureBases(featureID: second).isEmpty)
        try journal.recordFeatureBases(featureID: second, bases: [
            FeatureBaseRecord(repository: "mobile", baseRef: "refs/remotes/origin/main", baseCommit: "m1"),
            FeatureBaseRecord(
                repository: "backend", baseRef: "refs/yellowhammer/landed/yh/f-1", baseCommit: "b1",
                stackedOnFeatureID: first
            )
        ])
        #expect(try journal.featureBases(featureID: second).map(\.repository) == ["backend", "mobile"])
        #expect(try journal.featureBases(featureID: second).first?.stackedOnFeatureID == first)

        try journal.recordFeatureBases(featureID: second, bases: [
            FeatureBaseRecord(repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: "b2")
        ])
        let replaced = try journal.featureBases(featureID: second)
        #expect(replaced.count == 2)
        #expect(replaced.first == FeatureBaseRecord(
            repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: "b2"
        ))
    }
}
