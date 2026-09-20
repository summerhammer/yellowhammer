import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P9.7 (glossary: Refusal): the Journal-side store methods behind the author Act's
// uncitable-Definition-of-Done halt — recordRefusal, recordRefusalIssue, advanceRefusalClocks,
// resetConsecutiveRefusals and the readers. Bound arithmetic is exercised with a small configured
// unansweredNightsMax, per the roadmap item's done-when.

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

/// Opens one Night under a fresh run's Act Lease, releasing any run passed in first — mirroring how a
/// resumed or forced run leaves the lease between Acts in the fixtures elsewhere in this suite.
@discardableResult
private func openRefusalTestNight(
    _ journal: JournalStore, nightStart: String, previous: RunID? = nil
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

@Suite("Refusal store methods (P9.7)")
struct RefusalStoreTests {
    @Test("recordRefusal opens a new Refusal with consecutive count 1, and appends refusalOpened")
    func recordRefusalOpensNew() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (nightID, _) = try openRefusalTestNight(journal, nightStart: "2026-09-15")

        let outcome = try journal.recordRefusal(feature: feature, content: "no citable clauses", nightID: nightID)

        #expect(outcome.newlyOpened)
        #expect(!outcome.alreadyExpired)
        #expect(outcome.record.state == .open)
        #expect(outcome.record.consecutiveRefusals == 1)
        #expect(outcome.record.unansweredNights == 0)
        #expect(outcome.record.openedNightID == nightID)
        #expect(outcome.record.content == "no citable clauses")

        let events = try journal.events(ofType: .refusalOpened)
        #expect(events.count == 1)
    }

    @Test("A second recordRefusal while open increments the consecutive count, but leaves the clock untouched")
    func repeatRefusalWhileOpenDoesNotTouchClock() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "first", nightID: night1)

        let (night2, _) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        let outcome = try journal.recordRefusal(feature: feature, content: "second", nightID: night2)

        #expect(!outcome.newlyOpened)
        #expect(!outcome.alreadyExpired)
        #expect(outcome.record.state == .open)
        #expect(outcome.record.consecutiveRefusals == 2)
        #expect(outcome.record.content == "second")
        // The clock is untouched: still opened on night1, still zero unanswered Nights.
        #expect(outcome.record.openedNightID == night1)
        #expect(outcome.record.unansweredNights == 0)

        let events = try journal.events(ofType: .refusalRepeated)
        #expect(events.count == 1)
        guard case .refusalRepeated(_, let consecutiveRefusals) = events[0].event else {
            Issue.record("expected refusalRepeated")
            return
        }
        #expect(consecutiveRefusals == 2)
    }

    @Test("advanceRefusalClocks does not count the Night the Refusal opened on")
    func openingNightDoesNotCount() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, _) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        let expired = try journal.advanceRefusalClocks(nightID: night1, unansweredNightsMax: 1)

        #expect(expired.isEmpty)
        let refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.unansweredNights == 0)
        #expect(refusal.state == .open)
    }

    @Test("A second author Act of the same Night does not double-count the clock")
    func sameNightDoesNotDoubleCount() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        let (night2, _) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.advanceRefusalClocks(nightID: night2, unansweredNightsMax: 5)
        try journal.advanceRefusalClocks(nightID: night2, unansweredNightsMax: 5)

        let refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.unansweredNights == 1)
    }

    @Test("With unansweredNightsMax = 1: opens Night 1, still open at Night 2, expires at Night 3")
    func boundArithmeticExpiresOnThirdNight() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let bound = 1

        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)
        try journal.advanceRefusalClocks(nightID: night1, unansweredNightsMax: bound)
        var refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .open)
        #expect(refusal.unansweredNights == 0)

        let (night2, run2) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.advanceRefusalClocks(nightID: night2, unansweredNightsMax: bound)
        refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .open)
        #expect(refusal.unansweredNights == 1)

        let (night3, _) = try openRefusalTestNight(journal, nightStart: "2026-09-17", previous: run2)
        let expired = try journal.advanceRefusalClocks(nightID: night3, unansweredNightsMax: bound)
        refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .expired)
        #expect(refusal.unansweredNights == 2)
        #expect(refusal.expiredNightID == night3)
        #expect(refusal.content == "thin")
        #expect(expired.map(\.id) == [refusal.id])

        let events = try journal.events(ofType: .refusalExpired)
        #expect(events.count == 1)
    }

    @Test("A repeat refusal after expiry increments the consecutive count and stays expired")
    func repeatAfterExpiryStaysExpired() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        let (night2, run2) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.advanceRefusalClocks(nightID: night2, unansweredNightsMax: 0)
        var refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .expired)
        #expect(refusal.consecutiveRefusals == 1)

        let (night3, _) = try openRefusalTestNight(journal, nightStart: "2026-09-17", previous: run2)
        let outcome = try journal.recordRefusal(feature: feature, content: "still thin", nightID: night3)

        #expect(!outcome.newlyOpened)
        #expect(outcome.alreadyExpired)
        #expect(outcome.record.state == .expired)
        #expect(outcome.record.consecutiveRefusals == 2)

        refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .expired)
        #expect(refusal.consecutiveRefusals == 2)
    }

    @Test("A Project that runs no Night in between advances nothing extra: only Nights that ran count")
    func skippedCalendarDatesAdvanceNothing() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        // Night 2026-09-16 never runs; the next Act to fire is 2026-09-20, one Night later regardless
        // of how many calendar days passed.
        let (night2, _) = try openRefusalTestNight(journal, nightStart: "2026-09-20", previous: run1)
        try journal.advanceRefusalClocks(nightID: night2, unansweredNightsMax: 5)

        let refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.unansweredNights == 1)
    }

    @Test("recordRefusalIssue stores the issue id on the latest row for that Feature")
    func recordRefusalIssueStoresID() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, _) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        try journal.recordRefusalIssue(feature: feature, issueID: "FEAT-1")

        let refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.issueID == "FEAT-1")
    }

    @Test("resetConsecutiveRefusals answers the open row, zeroes the count, and touches only that Feature")
    func resetOnlyTouchesItsOwnFeature() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let other = try #require(FeatureName(rawValue: "FEAT-2"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)
        let (night2, _) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.recordRefusal(feature: other, content: "also thin", nightID: night2)

        let changed = try journal.resetConsecutiveRefusals(feature: feature, nightID: night2)

        #expect(changed)
        let refusal = try #require(try journal.refusals(feature: feature).first)
        #expect(refusal.state == .answered)
        #expect(refusal.consecutiveRefusals == 0)

        let untouched = try #require(try journal.refusals(feature: other).first)
        #expect(untouched.state == .open)
        #expect(untouched.consecutiveRefusals == 1)

        let events = try journal.events(ofType: .refusalCountReset)
        #expect(events.count == 1)
    }

    @Test("resetConsecutiveRefusals on a Feature with no Refusal is a no-op: nothing appended")
    func resetWithNoRowsIsNoOp() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-NONE"))

        let changed = try journal.resetConsecutiveRefusals(feature: feature)

        #expect(!changed)
        #expect(try journal.events(ofType: .refusalCountReset).isEmpty)
    }

    @Test("A new refusal opened after a reset starts its consecutive count at 1, not accumulating past reset")
    func newRefusalAfterResetStartsAtOne() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)
        let (night2, run2) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.recordRefusal(feature: feature, content: "still thin", nightID: night2)
        try journal.resetConsecutiveRefusals(feature: feature, nightID: night2)

        let (night3, _) = try openRefusalTestNight(journal, nightStart: "2026-09-17", previous: run2)
        let outcome = try journal.recordRefusal(feature: feature, content: "thin again", nightID: night3)

        #expect(outcome.newlyOpened)
        #expect(outcome.record.consecutiveRefusals == 1)
    }

    @Test("consecutiveRefusals reads the latest row's count, 0 when the Feature has none")
    func consecutiveRefusalsReader() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let untouchedFeature = try #require(FeatureName(rawValue: "FEAT-NONE"))
        let (night1, _) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        #expect(try journal.consecutiveRefusals(feature: feature) == 1)
        #expect(try journal.consecutiveRefusals(feature: untouchedFeature) == 0)
    }

    @Test("openRefusals lists only open rows, across Features")
    func openRefusalsReader() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let other = try #require(FeatureName(rawValue: "FEAT-2"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)
        let (night2, _) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        try journal.recordRefusal(feature: other, content: "also thin", nightID: night2)
        try journal.resetConsecutiveRefusals(feature: other, nightID: night2)

        let open = try journal.openRefusals()

        #expect(open.map(\.featureName) == ["FEAT-1"])
    }

    @Test("Other halt reasons create no Refusal row")
    func otherHaltReasonsCreateNoRow() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        _ = try openRefusalTestNight(journal, nightStart: "2026-09-15")

        // This test asserts the store side of the invariant only: nothing calls recordRefusal for a
        // non-uncitable halt reason (AuthoringHalt's own routing is exercised in EngineCommandTests).
        #expect(try journal.refusals(feature: feature).isEmpty)
        #expect(try journal.tableNames().contains("refusal"))
    }
}

@Suite("Refusal migration (P9.7)")
struct RefusalMigrationTests {
    @Test("v15-refusal is the last migration and creates the refusal table")
    func v15IsLastAndCreatesTable() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()

        #expect(try journal.appliedMigrations().last == "v15-refusal")
        #expect(JournalStore.migrationIdentifiers.last == "v15-refusal")
        #expect(try journal.tableNames().contains("refusal"))
    }

    @Test("At most one open Refusal per Feature name: a second insert violates the partial unique index")
    func onlyOneOpenRefusalPerFeature() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, _) = try openRefusalTestNight(journal, nightStart: "2026-09-15")
        try journal.recordRefusal(feature: feature, content: "thin", nightID: night1)

        // recordRefusal itself never inserts a second `open` row for the same Feature name — this
        // proves the index is actually there and would refuse one if something tried to.
        var threw = false
        do {
            try journal.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO refusal (
                        feature_name, state, content, opened_night_id, unanswered_nights, consecutive_refusals,
                        created_at
                    ) VALUES (?, 'open', 'dup', ?, 0, 1, ?)
                    """,
                    arguments: [feature.rawValue, night1, JournalStore.timestamp(Date())]
                )
            }
        } catch {
            threw = true
        }
        #expect(threw)
    }
}
