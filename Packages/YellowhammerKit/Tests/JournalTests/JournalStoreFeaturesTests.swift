import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// JournalStore+Features.swift (roadmap P8.1): the build Act's own read of the in-flight Feature and
// its Cards, and the write that records a Feature Branch name.

private struct FeaturesJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-features-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let featuresEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@discardableResult
private func insertFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(featuresEpoch)]
        )
        return db.lastInsertedRowID
    }
}

private func insertCycle(_ journal: JournalStore, featureID: Int64) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(featuresEpoch)]
        )
        return db.lastInsertedRowID
    }
}

@Test("inFlightFeature() returns nil with no open Cycle")
func inFlightFeatureNilWithNoOpenCycle() throws {
    let fixture = try FeaturesJournalFixture()
    let journal = try fixture.open()
    #expect(try journal.inFlightFeature() == nil)
}

@Test("inFlightFeature() returns the Feature with its branch after recordFeatureBranch")
func inFlightFeatureReturnsFeatureWithBranch() throws {
    let fixture = try FeaturesJournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFeature(journal, issueID: "FEAT-1")
    let cycleID = try insertCycle(journal, featureID: featureID)

    let before = try #require(try journal.inFlightFeature())
    #expect(before.feature.id == featureID)
    #expect(before.feature.branch == nil)
    #expect(before.cycleID == cycleID)

    let branch = FeatureBranch(rawValue: "yh-proj-feat")
    try journal.recordFeatureBranch(featureID: featureID, branch: branch)

    let after = try #require(try journal.inFlightFeature())
    #expect(after.feature.branch == branch)
}

@Test("recordFeatureBranch on an unknown Feature throws featureUnknown")
func recordFeatureBranchUnknownFeatureThrows() throws {
    let fixture = try FeaturesJournalFixture()
    let journal = try fixture.open()
    #expect(throws: JournalError.featureUnknown(featureID: 99)) {
        try journal.recordFeatureBranch(featureID: 99, branch: FeatureBranch(rawValue: "yh-x-y"))
    }
}

@Test("cards(cycleID:) orders by repository then authored order")
func cardsOrdersByRepositoryThenAuthoredOrder() throws {
    let fixture = try FeaturesJournalFixture()
    let journal = try fixture.open()
    let featureID = try insertFeature(journal, issueID: "FEAT-1")
    let cycleID = try insertCycle(journal, featureID: featureID)

    try journal.write { db in
        for (issueID, repository, order) in [
            ("MOB-1", "mobile", 1), ("BACK-2", "backend", 2), ("BACK-1", "backend", 1)
        ] {
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, issueID, repository, "card", order, CardState.todo.rawValue, 0,
                    JournalStore.timestamp(featuresEpoch)
                ]
            )
        }
    }

    let cards = try journal.cards(cycleID: cycleID)
    #expect(cards.map(\.issueID) == ["BACK-1", "BACK-2", "MOB-1"])
}
