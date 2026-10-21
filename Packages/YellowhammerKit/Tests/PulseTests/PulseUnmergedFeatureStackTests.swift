import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// feature-authoring/select-the-next-feature (`#unmerged-feature-stack`): the Pulse lists the Unmerged Feature
// Stack apart from the in-flight Feature, and says when an author firing skipped because it was full.

private struct StackFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-stack-\(UUID())")
    let projectID = ProjectID(rawValue: "fixture")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

/// A landed Feature of the fixture: where, and in which Night, its Cycle landed.
private struct LandedFeature {
    let issueID: String
    let display: String
    let repositories: [String]
    let nightID: Int64
    let run: RunID
}

/// Seeds a verified, landed, archived Feature that pushed in `repositories`, each with a Feature Branch.
private func seedLanded(_ journal: JournalStore, _ landed: LandedFeature) throws -> FixtureFeature {
    let feature = try insertFeature(journal, issueID: landed.issueID)
    try journal.write { db in
        try db.execute(
            sql: """
            UPDATE feature SET issue_id_for_display = ?, state = 'closed', closed_by = 'verification' WHERE id = ?
            """,
            arguments: [landed.display, feature.featureID]
        )
        try db.execute(
            sql: "UPDATE cycle SET landed_at = ?, archived_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), JournalStore.timestamp(epoch), feature.cycleID]
        )
    }
    for repository in landed.repositories {
        try journal.recordFeatureBranch(
            featureID: feature.featureID, repository: repository,
            branch: FeatureBranch(rawValue: "yh/\(landed.display.lowercased())")
        )
    }
    try journal.append(
        .cycleLanded(cycleID: feature.cycleID), act: .land, runID: landed.run, nightID: landed.nightID,
        now: epoch.addingTimeInterval(1)
    )
    return feature
}

/// Opens the first real Night under a land Act's lease.
private func openNight(_ journal: JournalStore) throws -> (nightID: Int64, run: RunID) {
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    return (opening.night.id, run)
}

private func pulse(_ journal: JournalStore) throws -> PulseSnapshot {
    try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))
}

private func openPullRequest(
    _ journal: JournalStore, _ featureID: Int64, _ repository: String, number: Int, night: (nightID: Int64, run: RunID)
) throws {
    try journal.recordPullRequest(
        featureID: featureID, repository: repository, url: "https://github.com/acme/\(repository)/pull/\(number)",
        nightID: night.nightID, runID: night.run, now: epoch.addingTimeInterval(2)
    )
}

@Test("Two Features landed tonight and unmerged are listed bottom-first, the second stacked on the first")
func twoFeaturesLandedTonightAwaitMerge() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    let first = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend"], nightID: night.nightID, run: night.run
    ))
    let second = try seedLanded(journal, LandedFeature(
        issueID: "feature-2", display: "YLH-2", repositories: ["backend", "web"], nightID: night.nightID,
        run: night.run
    ))
    try openPullRequest(journal, first.featureID, "backend", number: 7, night: night)
    try journal.recordFeatureBases(featureID: second.featureID, bases: [
        FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/yh/ylh-1", baseCommit: "b1",
            stackedOnFeatureID: first.featureID
        ),
        FeatureBaseRecord(repository: "web", baseRef: "refs/remotes/origin/main", baseCommit: "w1")
    ])

    let shown = try pulse(journal)

    #expect(shown.feature == nil)
    let stack = shown.unmergedFeatures
    #expect(stack.features.map(\.id) == ["feature-1", "feature-2"])
    let displayed = stack.features.compactMap { $0.issueIDForDisplay }
    #expect(displayed == ["YLH-1", "YLH-2"])
    let allTonight = stack.features.allSatisfy { $0.landedTonight }
    #expect(allTonight)
    #expect(stack.count == 2)
    #expect(stack.unmergedFeaturesMax == nil)
    #expect(!stack.isFull)
    let one = stack.features[0]
    #expect(one.mergedCount == 0)
    #expect(one.pushedCount == 1)
    #expect(one.repositories.first?.pullRequest?.number == 7)
    #expect(one.repositories.first?.branch == "yh/ylh-1")
    #expect(one.repositories.first?.stackedOn == nil)
    let two = stack.features[1]
    #expect(two.pushedCount == 2)
    #expect(two.repositories.map(\.repo) == ["backend", "web"])
    #expect(two.repositories.map(\.stackedOn) == ["YLH-1", nil])
    #expect(two.repositories.allSatisfy { $0.pullRequest == nil })
}

@Test("A Feature merged in one of two repositories stays listed with the split")
func partialMergeStaysListed() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    let feature = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend", "web"], nightID: night.nightID,
        run: night.run
    ))
    try journal.recordLanding(
        featureID: feature.featureID, repository: "web", mainlineCommit: "m1", evidence: .ancestry
    )

    let member = try #require(try pulse(journal).unmergedFeatures.features.first)

    #expect(member.mergedCount == 1)
    #expect(member.pushedCount == 2)
    #expect(member.repositories.map(\.merged) == [false, true])
}

@Test("A Feature merged in every pushed repository leaves the stack")
func fullyMergedLeavesTheStack() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    let feature = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend", "web"], nightID: night.nightID,
        run: night.run
    ))
    for repository in ["backend", "web"] {
        try journal.recordLanding(
            featureID: feature.featureID, repository: repository, mainlineCommit: "m-\(repository)", evidence: .ancestry
        )
    }

    #expect(try pulse(journal).unmergedFeatures.isEmpty)
}

@Test("The in-flight Feature is the group's Feature, stacked on a Feature in the stack")
func inFlightFeatureAndStackAreSeparate() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    let landed = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend"], nightID: night.nightID, run: night.run
    ))
    let building = try insertFeature(journal, issueID: "feature-2")
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET issue_id_for_display = 'YLH-2' WHERE id = ?", arguments: [building.featureID]
        )
    }
    try journal.recordFeatureBases(featureID: building.featureID, bases: [
        FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/yh/ylh-1", baseCommit: "b1",
            stackedOnFeatureID: landed.featureID
        ),
        FeatureBaseRecord(repository: "web", baseRef: "refs/remotes/origin/main", baseCommit: "w1")
    ])

    let shown = try pulse(journal)

    #expect(shown.feature?.id == "feature-2")
    #expect(shown.feature?.stackedOn == ["backend": "YLH-1"])
    #expect(shown.unmergedFeatures.features.map(\.id) == ["feature-1"])
}

@Test("A Feature landed on an earlier Night and still unmerged is listed, not landed tonight")
func earlierNightFeatureStaysListed() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    _ = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend"], nightID: night.nightID, run: night.run
    ))
    try journal.releaseActLease(runID: night.run)
    let nextRun = RunID()
    _ = try journal.claimActLease(act: .author, runID: nextRun, mode: .real, now: epoch.addingTimeInterval(100_000))
    _ = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-30")), mode: .real, act: .author, runID: nextRun,
        now: epoch.addingTimeInterval(100_000)
    )

    let member = try #require(
        try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(100_010))
            .unmergedFeatures.features.first
    )

    #expect(member.id == "feature-1")
    #expect(!member.landedTonight)
}

private func skip(
    _ journal: JournalStore, night: (nightID: Int64, run: RunID), names: [String], at offset: Double
) throws {
    let entries = names.map {
        UnmergedStackEntry(featureIssueID: "id-\($0)", identifier: $0, unmergedRepositories: ["backend"], branches: [:])
    }
    try journal.append(
        .authoringSkippedUnmergedStackFull(features: entries, unmergedFeaturesMax: names.count),
        act: .author, runID: night.run, nightID: night.nightID, now: epoch.addingTimeInterval(offset)
    )
}

@Test("Skipped authoring in the shown Night is counted, and the latest skip is the one named")
func stackFullSkipsAreCounted() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    try skip(journal, night: night, names: ["YLH-1"], at: 20)
    try skip(journal, night: night, names: ["YLH-1", "YLH-2"], at: 40)

    let found = try #require(try pulse(journal).night?.stackFullSkip)

    #expect(found.count == 2)
    #expect(found.features == ["YLH-1", "YLH-2"])
    #expect(found.unmergedFeaturesMax == 2)
    #expect(found.at == epoch.addingTimeInterval(40))
}

@Test("A skip recorded in an earlier Night does not show in the next one")
func stackFullSkipOfAnEarlierNightIsNotShown() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    try skip(journal, night: night, names: ["YLH-1"], at: 20)
    try journal.releaseActLease(runID: night.run)
    let nextRun = RunID()
    _ = try journal.claimActLease(act: .author, runID: nextRun, mode: .real, now: epoch.addingTimeInterval(100_000))
    _ = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-30")), mode: .real, act: .author, runID: nextRun,
        now: epoch.addingTimeInterval(100_000)
    )

    let shown = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(100_010))

    #expect(shown.night?.stackFullSkip == nil)
}

@Test("The Project's selection contains a Feature of the stack, and the stack is full at its Bound")
func selectionContainsStackFeature() throws {
    let fixture = StackFixture()
    let journal = try fixture.open()
    let night = try openNight(journal)
    _ = try seedLanded(journal, LandedFeature(
        issueID: "feature-1", display: "YLH-1", repositories: ["backend"], nightID: night.nightID, run: night.run
    ))
    var snapshot = ProjectSnapshot(
        id: fixture.projectID, name: "Fixture", repos: ["backend"], pulse: try pulse(journal)
    )

    #expect(snapshot.contains(.feature("feature-1")))
    #expect(!snapshot.contains(.feature("feature-9")))
    snapshot.pulse.unmergedFeatures.unmergedFeaturesMax = 1
    #expect(snapshot.pulse.unmergedFeatures.isFull)
    snapshot.pulse.unmergedFeatures.unmergedFeaturesMax = 2
    #expect(!snapshot.pulse.unmergedFeatures.isFull)
}
