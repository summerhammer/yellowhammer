import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.8 (glossary: Authoring Halt, Refusal): the Journal-side store methods behind the Authoring
// Halt as its own object — its clock, its independence from the Refusal's consecutive count — and the
// Refusal store's answer and close paths. Bound arithmetic is exercised with unansweredNightsMax = 1 and 2.

private struct HaltJournalFixture: ~Copyable {
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

private func haltNight(
    _ journal: JournalStore, _ nightStart: String, previous: RunID? = nil
) throws -> (nightID: Int64, runID: RunID) {
    if let previous {
        try journal.releaseActLease(runID: previous)
    }
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        Issue.record("Could not claim the Act Lease")
        return (0, runID)
    }
    let opening = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: nightStart)), mode: .rehearsal, act: .author, runID: runID
    )
    return (opening.night.id, runID)
}

private let seamKind = "no-backward-compatible-seam"

@Suite("Authoring Halt store (P9.8)")
struct AuthoringHaltStoreTests {
    private func feature(_ name: String = "FEAT-1") throws -> FeatureName {
        try #require(FeatureName(rawValue: name))
    }

    /// Opens a halt on night 1 and returns the Journal plus one further Night per name in `later`.
    private func openedHalt(
        _ fixture: borrowing HaltJournalFixture, later: [String]
    ) throws -> (journal: JournalStore, nights: [Int64]) {
        let journal = try fixture.open()
        var (night, run) = try haltNight(journal, "2026-09-15")
        try journal.recordAuthoringHalt(feature: try feature(), causeKind: seamKind, content: "first", nightID: night)
        var nights = [night]
        for start in later {
            (night, run) = try haltNight(journal, start, previous: run)
            nights.append(night)
        }
        return (journal, nights)
    }

    @Test("unansweredNightsMax = 1: not expired at the bound, expired one Night past it, content kept")
    func boundOfOne() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16", "2026-09-17"])

        #expect(try journal.advanceAuthoringHaltClocks(nightID: nights[0], unansweredNightsMax: 1).isEmpty)
        #expect(try journal.authoringHalts(feature: try feature())[0].unansweredNights == 0)

        #expect(try journal.advanceAuthoringHaltClocks(nightID: nights[1], unansweredNightsMax: 1).isEmpty)
        let atBound = try #require(try journal.authoringHalts(feature: try feature()).first)
        #expect(atBound.state == .open)
        #expect(atBound.unansweredNights == 1)

        let expired = try journal.advanceAuthoringHaltClocks(nightID: nights[2], unansweredNightsMax: 1)
        #expect(expired.map(\.featureName) == ["FEAT-1"])
        let record = try #require(try journal.expiredAuthoringHalts().first)
        #expect(record.state == .expired)
        #expect(record.content == "first")
        #expect(record.expiredNightID == nights[2])
        #expect(try journal.openAuthoringHalts().isEmpty)
        #expect(try journal.events(ofType: .authoringHaltExpired).count == 1)
    }

    @Test("unansweredNightsMax = 2: still open at two counted Nights, expired at the third")
    func boundOfTwo() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16", "2026-09-17", "2026-09-18"])

        for night in nights.dropFirst().prefix(2) {
            #expect(try journal.advanceAuthoringHaltClocks(nightID: night, unansweredNightsMax: 2).isEmpty)
        }
        #expect(try journal.openAuthoringHalts().first?.unansweredNights == 2)

        #expect(try journal.advanceAuthoringHaltClocks(nightID: nights[3], unansweredNightsMax: 2).count == 1)
        #expect(try journal.expiredAuthoringHalts().count == 1)
    }

    @Test("The Night a halt opened on never counts, and the same Night twice counts once")
    func openingNightAndSameNightCountOnce() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16"])

        try journal.advanceAuthoringHaltClocks(nightID: nights[0], unansweredNightsMax: 5)
        #expect(try journal.openAuthoringHalts().first?.unansweredNights == 0)

        try journal.advanceAuthoringHaltClocks(nightID: nights[1], unansweredNightsMax: 5)
        try journal.advanceAuthoringHaltClocks(nightID: nights[1], unansweredNightsMax: 5)
        #expect(try journal.openAuthoringHalts().first?.unansweredNights == 1)
    }

    @Test("A repeat halt replaces the content, leaves the clock alone and inserts no second row")
    func repeatLeavesClockAlone() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16"])
        try journal.advanceAuthoringHaltClocks(nightID: nights[1], unansweredNightsMax: 5)

        let outcome = try journal.recordAuthoringHalt(
            feature: try feature(), causeKind: seamKind, content: "second", nightID: nights[1]
        )

        #expect(!outcome.newlyOpened)
        #expect(!outcome.alreadyExpired)
        #expect(outcome.record.content == "second")
        #expect(outcome.record.openedNightID == nights[0])
        #expect(outcome.record.unansweredNights == 1)
        #expect(try journal.authoringHalts(feature: try feature()).count == 1)
        #expect(try journal.events(ofType: .authoringHaltRepeated).count == 1)
    }

    @Test("A halt against an already-expired halt is left alone")
    func expiredHaltIsLeftAlone() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16"])
        try journal.advanceAuthoringHaltClocks(nightID: nights[1], unansweredNightsMax: 0)

        let outcome = try journal.recordAuthoringHalt(
            feature: try feature(), causeKind: seamKind, content: "again", nightID: nights[1]
        )

        #expect(outcome.alreadyExpired)
        #expect(outcome.record.state == .expired)
        #expect(outcome.record.content == "first")
        #expect(try journal.authoringHalts(feature: try feature()).count == 1)
    }

    @Test("A halt never moves a Refusal's consecutive count")
    func haltNeverChangesConsecutiveRefusals() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: [])
        try journal.recordRefusal(feature: try feature("FEAT-2"), content: "thin", nightID: nights[0])

        try journal.recordAuthoringHalt(
            feature: try feature("FEAT-2"), causeKind: seamKind, content: "halt", nightID: nights[0]
        )

        #expect(try journal.consecutiveRefusals(feature: try feature("FEAT-2")) == 1)
        #expect(try journal.consecutiveRefusals(feature: try feature()) == 0)
        #expect(try journal.refusals(feature: try feature()).isEmpty)
    }

    @Test("A clean authoring run clears the halt, and a later halt opens a fresh row")
    func cleanRunClearsHalt() throws {
        let fixture = try HaltJournalFixture()
        let (journal, nights) = try openedHalt(fixture, later: ["2026-09-16"])

        #expect(try journal.clearAuthoringHalts(feature: try feature(), nightID: nights[1]))
        #expect(try journal.authoringHalts(feature: try feature()).map(\.state) == [.cleared])
        #expect(try !journal.clearAuthoringHalts(feature: try feature(), nightID: nights[1]))
        #expect(try journal.events(ofType: .authoringHaltCleared).count == 1)

        let again = try journal.recordAuthoringHalt(
            feature: try feature(), causeKind: seamKind, content: "back", nightID: nights[1]
        )
        #expect(again.newlyOpened)
    }
}

@Suite("Refusal answer and close (P9.8)")
struct RefusalAnswerStoreTests {
    private func feature() throws -> FeatureName { try #require(FeatureName(rawValue: "FEAT-1")) }

    @Test("answerRefusal answers an open Refusal, appends the event and leaves the count alone")
    func answersOpen() throws {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        let (night, _) = try haltNight(journal, "2026-09-15")
        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)

        let outcome = try #require(
            try journal.answerRefusal(feature: try feature(), citation: "epic/story", nightID: night)
        )

        #expect(outcome.previousState == .open)
        #expect(outcome.record.state == .answered)
        #expect(outcome.record.consecutiveRefusals == 1)
        let event = try #require(try journal.events(ofType: .refusalAnswered).first)
        #expect(event.event == .refusalAnswered(feature: "FEAT-1", citation: "epic/story", from: "open"))
    }

    @Test("answerRefusal answers an expired Refusal and reports its previous state")
    func answersExpired() throws {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        var (night, run) = try haltNight(journal, "2026-09-15")
        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)
        (night, run) = try haltNight(journal, "2026-09-16", previous: run)
        try journal.advanceRefusalClocks(nightID: night, unansweredNightsMax: 0)

        let outcome = try #require(try journal.answerRefusal(feature: try feature(), citation: "epic/story"))

        #expect(outcome.previousState == .expired)
        #expect(outcome.record.state == .answered)
        #expect(outcome.record.consecutiveRefusals == 1)
    }

    @Test("answerRefusal is a no-op with nothing answerable, including an already answered Refusal")
    func noOpOtherwise() throws {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        let (night, _) = try haltNight(journal, "2026-09-15")
        #expect(try journal.answerRefusal(feature: try feature(), citation: "x") == nil)

        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)
        try journal.answerRefusal(feature: try feature(), citation: "x")

        #expect(try journal.answerRefusal(feature: try feature(), citation: "y") == nil)
        #expect(try journal.events(ofType: .refusalAnswered).count == 1)
    }

    @Test("A clean run resets the count and closes the row without ever answering it; a new Refusal opens at 1")
    func cleanRunClosesWithoutAnswering() throws {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        var (night, run) = try haltNight(journal, "2026-09-15")
        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)
        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)
        (night, run) = try haltNight(journal, "2026-09-16", previous: run)

        try journal.resetConsecutiveRefusals(feature: try feature(), nightID: night)

        let row = try #require(try journal.refusals(feature: try feature()).first)
        #expect(row.state == .open)
        #expect(row.closedNightID == night)
        #expect(row.consecutiveRefusals == 0)
        #expect(try journal.openRefusals().isEmpty)
        // A closed row is off the clock.
        (night, run) = try haltNight(journal, "2026-09-17", previous: run)
        #expect(try journal.advanceRefusalClocks(nightID: night, unansweredNightsMax: 0).isEmpty)

        let fresh = try journal.recordRefusal(feature: try feature(), content: "again", nightID: night)
        #expect(fresh.newlyOpened)
        #expect(fresh.record.consecutiveRefusals == 1)
        #expect(try journal.refusals(feature: try feature()).count == 2)
    }

    @Test("A clean run leaves an expired Refusal's state and closure alone")
    func cleanRunLeavesExpiredAlone() throws {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        var (night, run) = try haltNight(journal, "2026-09-15")
        try journal.recordRefusal(feature: try feature(), content: "thin", nightID: night)
        (night, run) = try haltNight(journal, "2026-09-16", previous: run)
        try journal.advanceRefusalClocks(nightID: night, unansweredNightsMax: 0)

        try journal.resetConsecutiveRefusals(feature: try feature(), nightID: night)

        let row = try #require(try journal.refusals(feature: try feature()).first)
        #expect(row.state == .expired)
        #expect(row.closedNightID == nil)
        #expect(row.consecutiveRefusals == 0)
    }

    @Test("v17 migrates a v15 database that already holds refusal rows")
    func v17MigratesV15Database() throws {
        let fixture = try HaltJournalFixture()
        let fileURL = JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: fileURL.path)
        try JournalMigrations.migrator.migrate(queue, upTo: "v15-refusal")
        try queue.writeWithoutTransaction { db in
            try db.execute(
                sql: """
                INSERT INTO night (id, project_id, night_start, mode, state, opened_at)
                VALUES (1, 'fixture', '2026-09-15', 'rehearsal', 'open', '2026-09-15T00:00:00.000Z')
                """
            )
            for state in ["open", "answered"] {
                try db.execute(
                    sql: """
                    INSERT INTO refusal (
                        feature_name, state, content, opened_night_id, consecutive_refusals, created_at
                    )
                    VALUES ('FEAT-1', ?, 'thin', 1, 1, '2026-09-15T00:00:00.000Z')
                    """,
                    arguments: [state]
                )
            }
        }

        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v19-pull-request")
        #expect(try journal.tableNames().contains("authoring_halt"))
        let rows = try journal.refusals(feature: try feature())
        #expect(rows.map(\.state) == [.open, .answered])
        #expect(rows.allSatisfy { $0.closedNightID == nil })
        #expect(try journal.openRefusals().count == 1)
    }
}

@Suite("Authoring Halt and Refusal event encoding (P9.8)")
struct AuthoringStopEventEncodingTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func roundTrip(_ event: JournalEvent) throws -> JournalEvent {
        let fixture = try HaltJournalFixture()
        let journal = try fixture.open()
        try journal.append(event, act: .author, runID: RunID(), now: epoch)
        return try #require(try journal.events().first).event
    }

    @Test("Every new or changed event round-trips")
    func roundTrips() throws {
        let events: [JournalEvent] = [
            .refusalOpened(feature: "F", consecutiveRefusals: 2, uncitableClauses: "card:A:x", reselectionDepth: 3),
            .refusalRepeated(
                feature: "F", consecutiveRefusals: 3, uncitableClauses: "feature:-:y", reselectionDepth: 1
            ),
            .refusalAnswered(feature: "F", citation: "epic/story", from: "expired"),
            .authoringHaltOpened(feature: "F", causeKind: seamKind, detail: "the seam"),
            .authoringHaltOpened(feature: "F", causeKind: "repositories-undetermined", detail: nil),
            .authoringHaltRepeated(feature: "F", causeKind: seamKind, detail: "the seam"),
            .authoringHaltExpired(feature: "F", issueID: "ISS-1", unansweredNights: 2, bound: 1),
            .authoringHaltExpired(feature: "F", issueID: nil, unansweredNights: 2, bound: 1),
            .authoringHaltCleared(feature: "F")
        ]
        for event in events {
            #expect(try roundTrip(event) == event)
        }
    }

    @Test("No halt event's payload carries a consecutive count")
    func haltPayloadsHaveNoCount() {
        let events: [JournalEvent] = [
            .authoringHaltOpened(feature: "F", causeKind: seamKind, detail: nil),
            .authoringHaltRepeated(feature: "F", causeKind: seamKind, detail: nil),
            .authoringHaltExpired(feature: "F", issueID: nil, unansweredNights: 1, bound: 1),
            .authoringHaltCleared(feature: "F")
        ]
        for event in events {
            #expect(event.payload?.keys.contains { $0.contains("consecutive") } != true)
        }
    }

    @Test("A legacy refusalOpened payload without the new keys decodes with defaults")
    func legacyRefusalOpenedDecodes() throws {
        let decoded = try JournalEvent(
            type: .refusalOpened, payload: ["feature": "F", "consecutive_refusals": "1"], rowID: 1
        )
        #expect(decoded == .refusalOpened(
            feature: "F", consecutiveRefusals: 1, uncitableClauses: "", reselectionDepth: 0
        ))
    }

    @Test("A legacy featureAuthoringHalted row with the uncitable kind still decodes")
    func legacyHaltKindDecodes() throws {
        let decoded = try JournalEvent(
            type: .featureAuthoringHalted,
            payload: ["name": "F", "reason_kind": "uncitable-definition-of-done", "detail": "x"], rowID: 1
        )
        #expect(decoded == .featureAuthoringHalted(name: "F", reasonKind: "uncitable-definition-of-done", detail: "x"))
    }
}
