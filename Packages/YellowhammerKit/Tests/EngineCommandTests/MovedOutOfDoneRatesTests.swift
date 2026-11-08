import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// board-projection / moved-out-of-done: a Card moved out of Done counts as the G-9 observation input, so the
// "Green Cards accepted" instrumented rate treats it as reopened.

@Test("A Done Card moved out of Done before its Feature's Observed Merge is not a clean accepted Card")
func movedOutOfDoneCountsAsReopened() throws {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: base)
    let first = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-23")), mode: .real, act: .author, runID: run, now: base
    ).night
    let clean = try insertCard(journal, issueID: "CARD-1")
    let reopened = try insertCard(journal, issueID: "CARD-2")
    for (offset, id) in [(1.0, clean), (2.0, reopened)] {
        _ = try journal.transitionCard(
            cardID: id, to: .done, runID: run, act: .author, nightID: first.id, now: base.addingTimeInterval(offset)
        )
    }
    _ = try journal.transitionCard(
        cardID: reopened, to: .blocked, blockReason: .movedOutOfDone, runID: run, act: .author, nightID: first.id,
        now: base.addingTimeInterval(3)
    )
    _ = try journal.closeNight(id: first.id, reason: .nightEnd, act: .land, runID: run, now: base.addingTimeInterval(4))
    let second = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-09-24")), mode: .real, act: .author, runID: run,
        now: base.addingTimeInterval(5)
    ).night
    try journal.append(
        .verifiedFeatureMergeObserved(
            cycleID: try journal.card(id: clean).cycleID, featureIssueID: "FEAT-1", repositories: ["main"],
            acceptedCards: ["CARD-1", "CARD-2"], triagedNightID: first.id
        ),
        nightID: second.id, now: base.addingTimeInterval(6)
    )

    let lines = try NightSummary.instrumentedRateLines(
        night: try #require(try journal.night(id: second.id)), journal: journal, bounds: .init()
    )

    #expect(lines.contains { $0.contains("Green Cards accepted") && $0.contains("1/2 (50%)") })
}
