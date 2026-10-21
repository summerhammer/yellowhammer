import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// shift-scheduling/fire-an-act-on-schedule (periodic author firings): a Night can verify and land several
// Features. The Pulse keeps its single Feature group, strictly for the in-flight Feature, and counts every
// Feature verified tonight; the landed ones await merge in the Unmerged Feature Stack
// (`PulseUnmergedFeatureStackTests`).

private struct MultiFeatureFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-multi-\(UUID())")
    let projectID = ProjectID(rawValue: "fixture")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private struct LandingMoment {
    let nightID: Int64
    let run: RunID
    let offset: Double
}

/// Lands and archives a Feature's Cycle in `nightID`, with a Verification of `met` clauses all met.
private func landAndVerify(
    _ journal: JournalStore, issueID: String, display: String, met: Int, in night: LandingMoment
) throws {
    let (nightID, run, offset) = (night.nightID, night.run, night.offset)
    let feature = try insertFeature(journal, issueID: issueID)
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET issue_id_for_display = ? WHERE id = ?", arguments: [display, feature.featureID]
        )
        try db.execute(
            sql: "UPDATE cycle SET landed_at = ?, archived_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), JournalStore.timestamp(epoch), feature.cycleID]
        )
    }
    try journal.append(
        .cycleLanded(cycleID: feature.cycleID), act: .land, runID: run, nightID: nightID,
        now: epoch.addingTimeInterval(offset)
    )
    try journal.append(
        .featureVerified(cycleID: feature.cycleID, met: met, unmet: 0, unresolved: 0),
        act: .land, runID: run, nightID: nightID, now: epoch.addingTimeInterval(offset + 1)
    )
}

@Test("Two Features verified tonight are both counted, and the Feature group shows neither: none is in flight")
func twoFeaturesVerifiedTonight() throws {
    let fixture = MultiFeatureFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    try landAndVerify(
        journal, issueID: "feature-1", display: "YLH-1", met: 12,
        in: LandingMoment(nightID: opening.night.id, run: run, offset: 1)
    )
    try landAndVerify(
        journal, issueID: "feature-2", display: "YLH-2", met: 8,
        in: LandingMoment(nightID: opening.night.id, run: run, offset: 5)
    )

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.night?.verdictLine == "2 Features verified — all 20 clauses met")
    #expect(pulse.feature == nil)
}

@Test("A Feature landed on an earlier Night is not shown once the next Night has no Feature in flight")
func featureLandedOnAnEarlierNightIsNotShown() throws {
    let fixture = MultiFeatureFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    try landAndVerify(
        journal, issueID: "feature-1", display: "YLH-1", met: 12,
        in: LandingMoment(nightID: opening.night.id, run: run, offset: 1)
    )
    try journal.releaseActLease(runID: run)
    let nextRun = RunID()
    _ = try journal.claimActLease(act: .author, runID: nextRun, mode: .real, now: epoch.addingTimeInterval(100_000))
    let next = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-16")), mode: .real, act: .author, runID: nextRun,
        now: epoch.addingTimeInterval(100_000)
    )
    #expect(next.night.id != opening.night.id)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(100_010))

    #expect(pulse.feature == nil)
}
