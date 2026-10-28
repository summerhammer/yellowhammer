import Domain
@testable import Engine
import Foundation
@testable import Journal
@testable import Pulse
import Testing

private let holdEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private final class HoldReportingFixture {
    let directory: URL
    let journal: JournalStore
    let runID: RunID
    let night: NightRecord
    let cycleID: Int64
    let cardID: Int64

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(component: "yh-hold-report-\(UUID())")
        journal = try JournalStore.openSeeded(
            configurationDirectory: directory, projectID: #require(ProjectID(rawValue: "hold-report"))
        )
        runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: holdEpoch)
        night = try journal.openNight(
            nightStart: #require(NightStart(rawValue: "2026-10-28")), mode: .real,
            act: .build, runID: runID, now: holdEpoch
        ).night
        let ids: (Int64, Int64) = try journal.write { db in
            let timestamp = JournalStore.timestamp(holdEpoch)
            try db.execute(
                sql: "INSERT INTO feature(issue_id,state,created_at) VALUES ('F-1','selected',?)",
                arguments: [timestamp]
            )
            let featureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle(feature_id,created_at) VALUES (?,?)", arguments: [featureID, timestamp]
            )
            let cycleID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO card(
                    cycle_id,issue_id,repository,kind,authored_order,state,waiting_reason,budget_epoch,created_at
                )
                VALUES (?,'C-1','main','card',1,'Waiting on You','question',0,?)
                """, arguments: [cycleID, timestamp])
            return (cycleID, db.lastInsertedRowID)
        }
        cycleID = ids.0
        cardID = ids.1
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func beginHold(at start: Date = holdEpoch, minutes: Int = 30) throws {
        try journal.recordLandHold(
            nightID: night.id, cycleID: cycleID, cardIDs: [cardID], startedAt: start,
            endsAt: start.addingTimeInterval(Double(minutes) * 60), answerWaitMinutes: minutes,
            runID: runID, now: start
        )
    }
}

@Test("Pulse cues only the current hold and clears its cue on a different decision state or handoff")
func pulseLandHoldCue() throws {
    let fixture = try HoldReportingFixture()
    #expect(try PulseSnapshot.read(from: fixture.journal, status: .idle, asOf: holdEpoch)
        .needsYou.cards.first?.landHoldEndsAt == nil)
    try fixture.beginHold()
    #expect(try PulseSnapshot.read(from: fixture.journal, status: .idle, asOf: holdEpoch)
        .needsYou.cards.first?.landHoldEndsAt == holdEpoch.addingTimeInterval(1_800))
    try fixture.journal.write { db in
        try db.execute(sql: "UPDATE card SET waiting_reason = 'divergence' WHERE id = ?", arguments: [fixture.cardID])
    }
    #expect(try PulseSnapshot.read(from: fixture.journal, status: .idle, asOf: holdEpoch)
        .needsYou.cards.first?.landHoldEndsAt == nil)
    try fixture.journal.write { db in
        try db.execute(sql: "UPDATE card SET waiting_reason = 'question' WHERE id = ?", arguments: [fixture.cardID])
    }
    try fixture.journal.beginCycleHandoff(cycleID: fixture.cycleID, runID: fixture.runID, now: holdEpoch)
    #expect(try PulseSnapshot.read(from: fixture.journal, status: .idle, asOf: holdEpoch)
        .needsYou.cards.first?.landHoldEndsAt == nil)
}

@Test("Night Summary names a hold without any land tick and keeps it after the Card resumes")
func summaryLandHoldWithoutLandTick() throws {
    let fixture = try HoldReportingFixture()
    #expect(try NightSummary.answerWaitProximity(night: fixture.night, journal: fixture.journal) == nil)
    try fixture.beginHold()
    let resumedAt = holdEpoch.addingTimeInterval(120)
    try fixture.journal.endLandHold(
        cycleID: fixture.cycleID, reason: "answer or re-ready", runID: fixture.runID, now: resumedAt
    )
    try fixture.journal.write { db in
        try db.execute(
            sql: "UPDATE card SET state = 'Todo', waiting_reason = NULL WHERE id = ?", arguments: [fixture.cardID]
        )
    }
    #expect(try NightSummary.dispositionLines(night: fixture.night, journal: fixture.journal)
        .contains("`C-1` — kept the land Act from firing."))
    let proximity = try #require(try NightSummary.answerWaitProximity(night: fixture.night, journal: fixture.journal))
    #expect(proximity.observed == 2)
    #expect(proximity.value == 30)
    #expect(proximity.measure == "longest hold in minutes; answer or re-ready")
}

@Test("Hold restarts are separate spans and proximity caps the longest span at the Bound")
func summaryLandHoldLongestSpan() throws {
    let fixture = try HoldReportingFixture()
    try fixture.beginHold(minutes: 1)
    try fixture.journal.endLandHold(
        cycleID: fixture.cycleID, reason: "ran out", runID: fixture.runID, now: holdEpoch.addingTimeInterval(90)
    )
    let secondStart = holdEpoch.addingTimeInterval(100)
    try fixture.beginHold(at: secondStart, minutes: 1)
    try fixture.journal.endLandHold(
        cycleID: fixture.cycleID, reason: "answer or re-ready", runID: fixture.runID,
        now: secondStart.addingTimeInterval(20)
    )
    let proximity = try #require(try NightSummary.answerWaitProximity(night: fixture.night, journal: fixture.journal))
    #expect(proximity.observed == 1)
    #expect(proximity.value == 1)
    #expect(proximity.measure == "longest hold in minutes; ran out")
    #expect(try NightSummary.landHoldCardLines(night: fixture.night, journal: fixture.journal).count == 1)
}
