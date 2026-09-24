import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.8 (spec: landing/announce-a-partial-landing, morning-report/triage-the-morning):
// `closeFeatureByMerge` archives the Cycle `closed_by = 'merge'`, sets `night.triaged_at` on the
// triaged-Night rule's Night (first write wins), and appends `cycleArchived` then `featureClosedByMerge`
// once per Cycle. The V22 migration adds `night.triaged_at`, read back on `NightRecord.triagedAt`.

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
private let mergeClosureStoreNightStart = NightStart(rawValue: "2026-09-11")!

private func makeFeature(_ journal: JournalStore, issueID: String = "FEAT-1") throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func makeCycle(_ journal: JournalStore, featureID: Int64) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func featureRow(_ journal: JournalStore, featureID: Int64) throws -> (state: String, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT state, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["state"], row["closed_by"])
    }
}

@Suite("Journal migration V22: night.triaged_at (P10.8)")
struct NightTriagedAtMigrationTests {
    @Test("The V22 migration adds night.triaged_at, nullable, and it is the latest migration")
    func migrationAddsColumn() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        #expect(try journal.appliedMigrations().last == "v29-outbox-salt")

        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let opening = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        )
        #expect(opening.night.triagedAt == nil)
    }
}

@Suite("Close a Feature by merge, the Journal store (P10.8)")
struct MergeClosureStoreTests {
    @Test("A first call archives the Cycle, closed_by merge, sets triaged_at, and appends both events")
    func closesOnFirstCall() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let night = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        ).night

        let first = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: featureID, cycleID: cycleID, featureIssueID: "FEAT-1", triagedNightID: night.id,
                mergedRepositories: ["backend", "mobile"], carriedForward: ["BACK-2"], acceptedCards: ["BACK-1"],
                detachedCards: 1
            ),
            runID: runID, act: .author, nightID: night.id, now: epoch
        )

        #expect(first)
        let row = try featureRow(journal, featureID: featureID)
        #expect(row.state == "closed")
        #expect(row.closedBy == "merge")
        let updated = try #require(try journal.night(id: night.id))
        #expect(updated.triagedAt != nil)

        let archivedEvents = try journal.events(ofType: .cycleArchived)
        let closedEvents = try journal.events(ofType: .featureClosedByMerge)
        #expect(archivedEvents.count == 1)
        #expect(closedEvents.count == 1)
        let expectedArchived: JournalEvent = .cycleArchived(
            cycleID: cycleID, featureIssueID: "FEAT-1", closedBy: .merge, detachedCards: 1
        )
        #expect(archivedEvents[0].event == expectedArchived)
        let expectedClosed: JournalEvent = .featureClosedByMerge(
            cycleID: cycleID, featureIssueID: "FEAT-1", repositories: ["backend", "mobile"],
            carriedForward: ["BACK-2"], acceptedCards: ["BACK-1"], triagedNightID: night.id
        )
        #expect(closedEvents[0].event == expectedClosed)
    }

    @Test("A retry (already archived) is a no-op, appends nothing new, and returns false")
    func secondCallIsANoOp() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let night = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        ).night
        _ = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: featureID, cycleID: cycleID, featureIssueID: "FEAT-1", triagedNightID: night.id,
                mergedRepositories: ["backend"], carriedForward: [], acceptedCards: [], detachedCards: 0
            ),
            runID: runID, act: .author, nightID: night.id, now: epoch
        )

        let second = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: featureID, cycleID: cycleID, featureIssueID: "FEAT-1", triagedNightID: night.id,
                mergedRepositories: ["backend"], carriedForward: [], acceptedCards: [], detachedCards: 0
            ),
            runID: runID, act: .author, nightID: night.id, now: epoch
        )

        #expect(!second)
        let events = try journal.events(ofType: .featureClosedByMerge)
        #expect(events.count == 1)
    }

    @Test("night.triaged_at is first-write-wins: a later close of a different Feature never overwrites it")
    func triagedAtIsFirstWriteWins() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID1 = try makeFeature(journal, issueID: "FEAT-1")
        let cycleID1 = try makeCycle(journal, featureID: featureID1)
        let featureID2 = try makeFeature(journal, issueID: "FEAT-2")
        let cycleID2 = try makeCycle(journal, featureID: featureID2)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let night = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        ).night

        _ = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: featureID1, cycleID: cycleID1, featureIssueID: "FEAT-1", triagedNightID: night.id,
                mergedRepositories: ["backend"], carriedForward: [], acceptedCards: [], detachedCards: 0
            ),
            runID: runID, act: .author, nightID: night.id, now: epoch
        )
        let triagedAtFirst = try #require(try journal.night(id: night.id)).triagedAt

        _ = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: featureID2, cycleID: cycleID2, featureIssueID: "FEAT-2", triagedNightID: night.id,
                mergedRepositories: ["mobile"], carriedForward: [], acceptedCards: [], detachedCards: 0
            ),
            runID: runID, act: .author, nightID: night.id, now: epoch.addingTimeInterval(60)
        )

        #expect(try journal.night(id: night.id)?.triagedAt == triagedAtFirst)
    }

    @Test("An unknown Cycle id throws")
    func unknownCycleThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let night = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        ).night

        #expect(throws: JournalError.cycleUnknown(cycleID: 999)) {
            try journal.closeFeatureByMerge(
                NewFeatureMergeClosure(
                    featureID: featureID, cycleID: 999, featureIssueID: "FEAT-1", triagedNightID: night.id,
                    mergedRepositories: [], carriedForward: [], acceptedCards: [], detachedCards: 0
                ),
                runID: runID, act: .author, nightID: night.id, now: epoch
            )
        }
    }
}

@Suite("The triaged-Night rule (P10.8)")
struct TriagedNightRuleTests {
    @Test("With no recorded landing, the observing Night itself is triaged")
    func noLandingUsesTheObservingNight() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let cycleID = try makeCycle(journal, featureID: try makeFeature(journal))
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let night = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID, now: epoch
        ).night

        #expect(try journal.triagedNightID(cycleID: cycleID, currentNightID: night.id) == night.id)
    }

    @Test("The Night that landed the Cycle is triaged when it is earlier than the observing Night")
    func earlierLandingNightIsTriaged() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let landingNight = try journal.openNight(
            nightStart: NightStart(rawValue: "2026-09-09")!, mode: .real, act: .land, runID: runID, now: epoch
        ).night
        try journal.append(
            .cycleLanded(cycleID: cycleID), act: .land, runID: runID, nightID: landingNight.id, now: epoch
        )
        try journal.closeNight(id: landingNight.id, reason: .nightEnd, act: .land, runID: runID, now: epoch)
        try journal.releaseActLease(runID: runID)

        let runID2 = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID2, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        let observingNight = try journal.openNight(
            nightStart: mergeClosureStoreNightStart, mode: .real, act: .author, runID: runID2, now: epoch
        ).night

        #expect(try journal.triagedNightID(cycleID: cycleID, currentNightID: observingNight.id) == landingNight.id)
    }
}
