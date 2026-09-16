import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-absent-night-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Test("Night 09-12 recorded, then open 09-15 → absent Nights for 09-13 and 09-14")
func absentNightsBetweenTwoNights() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-09-12")!
    let opening1 = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journal.releaseActLease(runID: run1)

    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(3 * 86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-15")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(3 * 86400)
    )

    #expect(opening2.absentNights == [
        NightStart(rawValue: "2026-09-13")!,
        NightStart(rawValue: "2026-09-14")!
    ])

    let events = try journal.events()
    let absents = try journal.absentNights(nightID: opening2.night.id)
    #expect(absents == [
        NightStart(rawValue: "2026-09-13")!,
        NightStart(rawValue: "2026-09-14")!
    ])
}

@Test("Consecutive Nights → empty absent list and no event")
func consecutiveNightsEmptyAbsent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-09-14")!
    let opening1 = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journal.releaseActLease(runID: run1)

    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-15")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(86400)
    )

    #expect(opening2.absentNights.isEmpty)

    let absentEvents = try journal.events(ofType: .absentNightDetected)
    #expect(absentEvents.isEmpty)
}

@Test("Very first Night of a Journal → empty absent list and no event")
func firstNightNoAbsent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    let nightStart = NightStart(rawValue: "2026-09-15")!
    let opening = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch
    )

    #expect(opening.absentNights.isEmpty)

    let absentEvents = try journal.events(ofType: .absentNightDetected)
    #expect(absentEvents.isEmpty)
}

@Test("Repeat open (second Act of same Night) → empty absent list and no new event")
func repeatOpenNoAdditionalAbsent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    // Record first Night on 09-12
    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)
    let night1Start = NightStart(rawValue: "2026-09-12")!
    _ = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journal.releaseActLease(runID: run1)

    // First Act of Night on 09-15 (gap: 09-13, 09-14)
    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(3 * 86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-15")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(3 * 86400)
    )
    #expect(opening2.absentNights.count == 2)
    try journal.releaseActLease(runID: run2)

    // Second Act of same Night (repeat open)
    let run3 = RunID()
    _ = try journal.claimActLease(
        act: .build, runID: run3, mode: .real,
        now: epoch.addingTimeInterval(3 * 86400 + 100)
    )
    let opening3 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .build, runID: run3,
        now: epoch.addingTimeInterval(3 * 86400 + 100)
    )
    #expect(opening3.absentNights.isEmpty)

    // Should still only have 2 absent night events (from first Act of Night on 09-15)
    let absentEvents = try journal.events(ofType: .absentNightDetected)
    #expect(absentEvents.count == 2)
}

@Test("Last recorded Night left open (opened-and-died), then open new Night → audit finds gap")
func auditFindsGapAfterOpenedAndDiedNight() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-09-12")!
    _ = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    // Don't close it — leave it open (simulating opened-and-died)
    try journal.releaseActLease(runID: run1)

    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(3 * 86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-15")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(3 * 86400)
    )

    let events = try journal.events()
    let eventTypes = events.map(\.type)
    // nightOpened (09-12), nightOpened (09-15), nightOpenedAndDied (09-12),
    // absentNightDetected (09-13), absentNightDetected (09-14)
    #expect(eventTypes == [
        .nightOpened, .nightOpened, .nightOpenedAndDied, .absentNightDetected, .absentNightDetected
    ])

    #expect(opening2.absentNights == [
        NightStart(rawValue: "2026-09-13")!,
        NightStart(rawValue: "2026-09-14")!
    ])
}

@Test("Month boundary: 08-30 then 09-02 → absent Nights for 08-31 and 09-01")
func absentNightsAcrossMonthBoundary() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-08-30")!
    _ = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journal.releaseActLease(runID: run1)

    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(3 * 86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-02")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(3 * 86400)
    )

    #expect(opening2.absentNights == [
        NightStart(rawValue: "2026-08-31")!,
        NightStart(rawValue: "2026-09-01")!
    ])
}

@Test("Year boundary: 2026-12-31 then 2027-01-02 → absent Night for 2027-01-01")
func absentNightsAcrossYearBoundary() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-12-31")!
    _ = try journal.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journal.releaseActLease(runID: run1)

    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(2 * 86400)
    )
    let night2Start = NightStart(rawValue: "2027-01-02")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(2 * 86400)
    )

    #expect(opening2.absentNights == [NightStart(rawValue: "2027-01-01")!])
}

@Test("Bounds unchanged: card with unanswered_nights remains unchanged after absent Night audit")
func boundsUnchangedByAbsentNightAudit() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    // Insert a feature/cycle/card fixture
    let timestamp = epoch.formatted(.iso8601)
    try journal.write { db in
        // Create a feature
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-1", "In Progress", timestamp]
        )
        let featureID = db.lastInsertedRowID

        // Create a cycle
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, timestamp]
        )
        let cycleID = db.lastInsertedRowID

        // Create a card with unanswered_nights = 1
        try db.execute(
            sql: """
            INSERT INTO card (
              cycle_id, issue_id, repository, kind, authored_order, state,
              waiting_reason, unanswered_nights, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, "card-1", "main", "card", 1, "Waiting on You",
                "question", 1, 0, timestamp
            ]
        )
    }

    // Record first Night on 09-10
    let run1 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)
    let night1Start = NightStart(rawValue: "2026-09-10")!
    _ = try journal.openNight(nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch)
    try journal.releaseActLease(runID: run1)

    // Open new Night on 09-15 (4 absent Nights: 09-11, 09-12, 09-13, 09-14)
    let run2 = RunID()
    _ = try journal.claimActLease(
        act: .author, runID: run2, mode: .real,
        now: epoch.addingTimeInterval(5 * 86400)
    )
    let night2Start = NightStart(rawValue: "2026-09-15")!
    let opening2 = try journal.openNight(
        nightStart: night2Start, mode: .real, act: .author, runID: run2,
        now: epoch.addingTimeInterval(5 * 86400)
    )
    #expect(opening2.absentNights.count == 4)

    // Verify card row is unchanged
    try verifyCardUnchanged(journal: journal)
}

private func verifyCardUnchanged(journal: JournalStore) throws {
    try journal.read { db in
        if let row = try Row.fetchOne(
            db, sql: "SELECT * FROM card WHERE issue_id = ?", arguments: ["card-1"]
        ) {
            let state: String = row["state"]
            let unansweredNights: Int = row["unanswered_nights"]
            let blockReason: String? = row["block_reason"]

            #expect(state == "Waiting on You")
            #expect(unansweredNights == 1)
            #expect(blockReason == nil)
        } else {
            Issue.record("Card not found")
        }
    }
}

@Test("NightStart Comparable: < operator and ordering")
func nightStartComparable() throws {
    let night1 = NightStart(rawValue: "2026-09-12")!
    let night2 = NightStart(rawValue: "2026-09-15")!
    let night3 = NightStart(rawValue: "2026-09-15")!

    #expect(night1 < night2)
    #expect(!(night2 < night1))
    #expect(!(night2 < night3))
    #expect(night1 <= night2)
    #expect(night2 <= night3)
    #expect(night2 >= night1)
}

@Test("NightStart.dates with reversed arguments returns empty")
func datesWithReversedArgumentsEmpty() throws {
    let night1 = NightStart(rawValue: "2026-09-15")!
    let night2 = NightStart(rawValue: "2026-09-12")!

    let result = NightStart.dates(strictlyBetween: night1, and: night2)
    #expect(result.isEmpty)
}

@Test("NightStart.dates with equal arguments returns empty")
func datesWithEqualArgumentsEmpty() throws {
    let night = NightStart(rawValue: "2026-09-15")!

    let result = NightStart.dates(strictlyBetween: night, and: night)
    #expect(result.isEmpty)
}
