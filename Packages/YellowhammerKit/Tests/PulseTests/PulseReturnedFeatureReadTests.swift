import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// verification/return-a-feature-with-unmet-clauses and app/land-on-the-sidebar-and-pulse: a Feature the land
// Act returned is shown, not hidden — its state, its Roll-up word, its clause tally, a Needs you row, and the
// Night's verdict line.

/// A throwaway configuration directory holding one Project's Journal. Removed on deinit, so a test creates it
/// in its own body: a helper returning it would delete the Journal under the caller.
private struct ReturnFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-pulse-return-\(UUID())")
    let projectID = ProjectID(rawValue: "fixture")! // swiftlint:disable:this force_unwrapping

    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let featureIssueID = "6f0c2b1e-3a52-4d6a-9d1c-0a7a4b9f1e11"

private func clause(_ index: Int, _ verdict: ClauseVerdict) -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: featureIssueID, cid: "C\(index)", level: "feature", text: "clause \(index)", locationID: "loc",
        citationProvenance: "machine-found", verdict: verdict, whatWasChecked: "checked", interpretation: "read",
        judgedBy: .agent
    )
}

/// A Feature with a landed Cycle of three Done Cards, returned to the Operator after a Verification of 18 met
/// and 4 unmet clauses, in a Night that recorded `FeatureVerified` and `FeatureReturned`.
private func seedReturnedFeature(_ journal: JournalStore) throws -> (nightID: Int64, run: RunID) {
    let feature = try insertFeature(journal, issueID: featureIssueID)
    for index in 1...3 {
        try insertCard(journal, cycleID: feature.cycleID, issueID: "C-\(index)", state: .done, order: index)
    }
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    let nightID = opening.night.id
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET state = 'returned', issue_id_for_display = 'YLH-347' WHERE id = ?",
            arguments: [feature.featureID]
        )
        try db.execute(
            sql: "UPDATE cycle SET landed_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), feature.cycleID]
        )
    }
    let clauses = (1...18).map { clause($0, .met) } + (19...22).map { clause($0, .unmet) }
    try journal.recordFeatureVerification(
        NewFeatureVerification(
            featureID: feature.featureID, cycleID: feature.cycleID, route: nil, nightID: nightID, runID: run,
            clauses: clauses
        ),
        now: epoch
    )
    try journal.append(
        .featureVerified(cycleID: feature.cycleID, met: 18, unmet: 4, unresolved: 0),
        act: .land, runID: run, nightID: nightID, now: epoch.addingTimeInterval(1)
    )
    try journal.append(
        .featureReturned(cycleID: feature.cycleID, featureIssueID: featureIssueID, unmet: 4, unresolved: 0),
        act: .land, runID: run, nightID: nightID, now: epoch.addingTimeInterval(2)
    )
    return (nightID, run)
}

@Test("A returned Feature shows its state, Roll-up and clause tally, and is a Needs you row")
func returnedFeatureIsShown() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    _ = try seedReturnedFeature(journal)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.feature?.state == "returned")
    #expect(pulse.feature?.rollupState == .waiting)
    #expect(pulse.feature?.verification == VerificationCounts(met: 18, unmet: 4, unresolved: 0))
    #expect(pulse.needsYou.returnedFeature?.id == featureIssueID)
    #expect(pulse.needsYou.returnedFeature?.issueIDForDisplay == "YLH-347")
    #expect(pulse.needsYou.returnedFeature?.verification?.total == 22)
    #expect(pulse.needsYou.waitingOnYouCount == 1)
    #expect(pulse.needsYou.count == 1)
    #expect(!pulse.needsYou.isEmpty)
    #expect(pulse.needsYou.cards.isEmpty)
    #expect(pulse.needsYou.blockReasonCounts.isEmpty)
    #expect(pulse.night?.verdictLine == "Feature YLH-347 returned — 4 of 22 clauses unmet")
    #expect(pulse.night?.state == .running)
}

@Test("A selected, running Feature reads running with no tally, no Needs you row and no verdict line")
func runningFeatureHasNoReturn() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: featureIssueID)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .todo, order: 1)
    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-2", state: .todo, order: 2)
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    _ = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.feature?.state == "selected")
    #expect(pulse.feature?.rollupState == .running)
    #expect(pulse.feature?.verification == nil)
    #expect(pulse.needsYou.returnedFeature == nil)
    #expect(pulse.needsYou.isEmpty)
    #expect(pulse.needsYou.waitingOnYouCount == 0)
    #expect(pulse.night?.verdictLine == nil)
}

@Test("A Feature with a Cycle and no Cards reads authoring; one whose Cards are all Shelved has no word")
func rollupAtTheEdges() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: featureIssueID)

    #expect(try PulseSnapshot.read(from: journal, status: .idle).feature?.rollupState == .authoring)

    try insertCard(journal, cycleID: feature.cycleID, issueID: "C-1", state: .shelved, order: 1)

    #expect(try PulseSnapshot.read(from: journal, status: .idle).feature?.rollupState == nil)
}

@Test("A return and failed Act runs both appear in the verdict line, the Feature fact first")
func verdictLineComposesTheReturnAndFailures() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let seeded = try seedReturnedFeature(journal)
    try journal.append(
        .actIncomplete(reason: "Linear returned 503"), act: .build, runID: RunID(), nightID: seeded.nightID,
        now: epoch.addingTimeInterval(3)
    )

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(
        pulse.night?.verdictLine
            == "Feature YLH-347 returned — 4 of 22 clauses unmet · 1 Act run failed — see Health"
    )
}

@Test("A fully verified Feature is named in the verdict line, found through its Cycle")
func verifiedFeatureVerdictLine() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: featureIssueID)
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET issue_id_for_display = 'YLH-350' WHERE id = ?", arguments: [feature.featureID]
        )
    }
    try journal.append(
        .featureVerified(cycleID: feature.cycleID, met: 12, unmet: 0, unresolved: 0),
        act: .land, runID: run, nightID: opening.night.id, now: epoch.addingTimeInterval(1)
    )

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.night?.verdictLine == "Feature YLH-350 verified — all 12 clauses met")
}

@Test("A returned Feature with not checked clauses appends ', <x> not checked' to verdictLine and tally")
func returnedFeatureWithNotCheckedClauses() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: featureIssueID)
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    try journal.write { db in
        try db.execute(
            sql: "UPDATE feature SET issue_id_for_display = 'YLH-355', state = 'returned' WHERE id = ?",
            arguments: [feature.featureID]
        )
        try db.execute(
            sql: "UPDATE cycle SET landed_at = ? WHERE id = ?",
            arguments: [JournalStore.timestamp(epoch), feature.cycleID]
        )
    }
    let clauses = (1...18).map { clause($0, .met) }
        + (19...22).map { clause($0, .unmet) }
        + (23...24).map { clause($0, .notChecked) }
    try journal.recordFeatureVerification(
        NewFeatureVerification(
            featureID: feature.featureID, cycleID: feature.cycleID, route: nil, nightID: opening.night.id, runID: run,
            clauses: clauses
        ),
        now: epoch
    )
    try journal.append(
        .featureVerified(cycleID: feature.cycleID, met: 18, unmet: 4, unresolved: 0, notChecked: 2),
        act: .land, runID: run, nightID: opening.night.id, now: epoch.addingTimeInterval(1)
    )
    try journal.append(
        .featureReturned(
            cycleID: feature.cycleID,
            featureIssueID: featureIssueID,
            unmet: 4,
            unresolved: 0,
            notChecked: 2
        ),
        act: .land, runID: run, nightID: opening.night.id, now: epoch.addingTimeInterval(2)
    )

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.feature?.verification == VerificationCounts(met: 18, unmet: 4, unresolved: 0, notChecked: 2))
    #expect(pulse.feature?.verification?.total == 24)
    #expect(pulse.night?.verdictLine == "Feature YLH-355 returned — 4 of 24 clauses unmet, 2 not checked")
}

@Test("A Feature with not checked clauses is never reported as verified all met")
func featureWithNotCheckedClausesIsNotAllMet() throws {
    let fixture = ReturnFixture()
    let journal = try fixture.open()
    let feature = try insertFeature(journal, issueID: featureIssueID)
    let run = RunID()
    _ = try journal.claimActLease(act: .land, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .land, runID: run, now: epoch)
    try journal.append(
        .featureVerified(cycleID: feature.cycleID, met: 12, unmet: 0, unresolved: 0, notChecked: 1),
        act: .land, runID: run, nightID: opening.night.id, now: epoch.addingTimeInterval(1)
    )

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch.addingTimeInterval(10))

    #expect(pulse.night?.verdictLine == nil)
}
