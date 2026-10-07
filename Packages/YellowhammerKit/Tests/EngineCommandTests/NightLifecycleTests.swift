import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

private let nightStart = NightStart(rawValue: "2026-09-15")!
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let route = Route(cli: "claude", model: "opus", effort: "high")!

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

private final class ResultBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value?>
    init() { storage = Mutex(nil) }
    func set(_ value: Value) { storage.withLock { $0 = value } }
    var value: Value? { storage.withLock { $0 } }
}

@Test("Author invocation with unmet trigger opens Night and records it")
func authorWithUnmetTriggerOpensNight() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    // Insert a todo card to make author trigger false
    try journal.write { db in
        let timestamp = epoch.formatted(.iso8601)
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["CARD-1", "selected", timestamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, "CARD-1", "main", "card", 1, CardState.todo.rawValue, 0, timestamp]
        )
    }

    let invocation = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .scheduled,
        runID: run,
        work: { _ in Issue.record("Work should not run") }
    )

    try await invocation.run()

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actIdle, .actEnded])
    let night = try #require(try journal.currentNight())
    #expect(night.state == .opened)
    #expect(night.nightStart == nightStart)
    // Every event of the Act is an event of its Night.
    #expect(events.map(\.nightID) == Array(repeating: night.id, count: 4))
}

@Test("Land invocation with closesNight: true closes the Night")
func landWithClosesNightCloses() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let invocation = EngineInvocation(
        act: .land,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: run,
        closesNight: true,
        work: { _ in }
    )

    try await invocation.run()

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .nightClosed, .actEnded])
    let night = try journal.currentNight()
    #expect(night == nil)
}

@Test("Land invocation with unmet trigger and closesNight: true still closes Night")
func landWithUnmetTriggerAndClosesNightCloses() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let invocation = EngineInvocation(
        act: .land,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .scheduled,
        runID: run,
        closesNight: true,
        work: { _ in Issue.record("Work should not run") }
    )

    try await invocation.run()

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actIdle, .nightClosed, .actEnded])
    let night = try journal.currentNight()
    #expect(night == nil)
}

@Test("Build invocation does not close Night")
func buildDoesNotCloseNight() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: run,
        closesNight: false,
        work: { _ in }
    )

    try await invocation.run()

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .actStarted, .actEnded])
    let night = try journal.currentNight()
    #expect(night?.state == .opened)
}

@Test("Second invocation of same Night uses existing Night")
func secondInvocationUsesSameNight() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()

    let invocation1 = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: run1,
        work: { _ in }
    )
    try await invocation1.run()

    let night1 = try journal.currentNight()
    let nightID1 = night1?.id

    let invocation2 = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: run2,
        work: { _ in }
    )
    try await invocation2.run()

    let night2 = try journal.currentNight()
    let nightID2 = night2?.id

    #expect(nightID1 == nightID2)
}

@Test("Opened-and-died end-to-end: killed invocation, next invocation sweeps")
func openedAndDiedEndToEnd() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()
    let nightStart1 = NightStart(rawValue: "2026-09-14")!

    // First invocation with forced work that gets killed
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let invocation1 = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: nightStart1,
        journal: journal,
        trigger: .forced,
        runID: run1,
        work: { _ in
            continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        }
    )

    let task = Task { try await invocation1.run() }
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    let night1 = try journal.currentNight()
    #expect(night1?.state == .opened)

    // Second invocation for new night
    let invocation2 = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: run2,
        work: { _ in }
    )
    try await invocation2.run()

    let events = try journal.events()
    let openedAndDiedEvents = events.filter { $0.type == .nightOpenedAndDied }
    #expect(openedAndDiedEvents.count == 1)

    let night1Closed = try journal.night(id: night1!.id)
    #expect(night1Closed?.state == .closed)
    #expect(night1Closed?.closeReason == .openedAndDied)
}

@Test("Absent Nights end-to-end: two author invocations with gap records AbsentNightDetected events")
func absentNightsEndToEnd() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()

    let night1Start = NightStart(rawValue: "2026-09-13")!
    let invocation1 = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: night1Start,
        journal: journal,
        trigger: .forced,
        runID: run1,
        work: { _ in }
    )
    try await invocation1.run()

    let night2Start = NightStart(rawValue: "2026-09-16")!
    let invocation2 = EngineInvocation(
        act: .author,
        mode: .real,
        nightStart: night2Start,
        journal: journal,
        trigger: .forced,
        runID: run2,
        work: { _ in }
    )
    try await invocation2.run()

    let events = try journal.events()
    let absents = events.filter { $0.type == .absentNightDetected }
    #expect(absents.count == 2)

    // Verify event content
    guard case .absentNightDetected(let ns1) = absents[0].event else {
        Issue.record("First absent event is not absentNightDetected")
        return
    }
    guard case .absentNightDetected(let ns2) = absents[1].event else {
        Issue.record("Second absent event is not absentNightDetected")
        return
    }

    #expect(ns1 == NightStart(rawValue: "2026-09-14"))
    #expect(ns2 == NightStart(rawValue: "2026-09-15"))

    // Verify all absent events are stamped with the second Night's id
    let night2 = try journal.currentNight()
    #expect(absents.allSatisfy { $0.nightID == night2?.id })

    // Verify absentNights(nightID:) returns the same Nights
    let absentNights = try journal.absentNights(nightID: night2!.id)
    #expect(absentNights == [
        NightStart(rawValue: "2026-09-14")!,
        NightStart(rawValue: "2026-09-15")!
    ])
}

/// `now` at a wall-clock time on a given day of the current calendar, so the test is time-zone
/// independent: the command decides against `Calendar.current`, and so does the test.
private func localDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
    try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
}

@Test("The land firing at night_end is the one that closes the Night; build never does")
func makeInvocationDecidesClosesNightFromTheSchedule() throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let atNightEnd = try localDate(year: 2026, month: 9, day: 16, hour: 6)
    let midNight = try localDate(year: 2026, month: 9, day: 15, hour: 23)

    let land = try LandCommand.parse(["--project", "alpha"])
    let closing = try land.makeInvocation(configurationDirectory: directory.url, now: atNightEnd)
    #expect(closing.closesNight)
    #expect(closing.nightStart == NightStart(rawValue: "2026-09-15"))

    let notYet = try land.makeInvocation(configurationDirectory: directory.url, now: midNight)
    #expect(!notYet.closesNight)
    #expect(notYet.nightStart == NightStart(rawValue: "2026-09-15"))

    let build = try BuildCommand.parse(["--project", "alpha"])
    let building = try build.makeInvocation(configurationDirectory: directory.url, now: atNightEnd)
    #expect(!building.closesNight)
    #expect(building.nightStart == NightStart(rawValue: "2026-09-15"))
}

@Test("--night moves only the Night's identity; closesNight still follows the given Night's night_end")
func makeInvocationWithNightOverridesIdentityNotClock() throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha", rehearsal: true)

    // now is fixed; only --night should decide nightStart, regardless of what now's own Night is.
    let now = try localDate(year: 2026, month: 9, day: 20, hour: 12)

    let land = try LandCommand.parse(["--project", "alpha", "--rehearsal", "--night", "2026-01-10"])
    let invocation = try land.makeInvocation(configurationDirectory: directory.url, now: now)
    #expect(invocation.nightStart == NightStart(rawValue: "2026-01-10"))

    // A land Act for a past date's Night, whose night_end (06:00 the next day) is long past `now`, closes it.
    #expect(invocation.closesNight)

    // A land Act for a future date's Night does not close it: its night_end has not happened yet.
    let futureLand = try LandCommand.parse(["--project", "alpha", "--rehearsal", "--night", "2027-01-10"])
    let futureInvocation = try futureLand.makeInvocation(configurationDirectory: directory.url, now: now)
    #expect(futureInvocation.nightStart == NightStart(rawValue: "2027-01-10"))
    #expect(!futureInvocation.closesNight)
}
