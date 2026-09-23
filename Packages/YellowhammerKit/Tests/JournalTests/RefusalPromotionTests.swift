import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P11.6 (bounds/overview): the refusal-drift promotion Bound. A Refusal is
// promoted once its consecutive count exceeds `consecutiveRefusalsMax` — visibility only: `state` is
// never touched, only the nullable `standing_item_night_id` marker and one `refusalPromotedToStandingItem`
// event. `JournalFixture` and `openRefusalTestNight` mirror RefusalStoreTests.swift, kept private per file.

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

@Suite("Refusal-drift promotion, consecutiveRefusalsMax = 1 (P11.6)")
struct RefusalPromotionTests {
    @Test("First Refusal: count 1, not promoted; second: count 2 > 1, promoted once; third: still promoted")
    func promotesOnceAndStays() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")

        let first = try journal.recordRefusal(
            feature: feature, content: "thin", consecutiveRefusalsMax: 1, nightID: night1
        )
        #expect(first.record.consecutiveRefusals == 1)
        #expect(first.record.standingItemNightID == nil)
        #expect(first.record.state == .open)

        let (night2, run2) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        let second = try journal.recordRefusal(
            feature: feature, content: "still thin", consecutiveRefusalsMax: 1, nightID: night2
        )
        #expect(second.record.consecutiveRefusals == 2)
        #expect(second.record.standingItemNightID == night2)
        #expect(second.record.state == .open)
        #expect(try journal.events(ofType: .refusalPromotedToStandingItem).count == 1)

        let (night3, _) = try openRefusalTestNight(journal, nightStart: "2026-09-17", previous: run2)
        let third = try journal.recordRefusal(
            feature: feature, content: "thin again", consecutiveRefusalsMax: 1, nightID: night3
        )
        #expect(third.record.consecutiveRefusals == 3)
        // Promoted once: the marker does not move to the later Night, and no second event was appended.
        #expect(third.record.standingItemNightID == night2)
        #expect(try journal.events(ofType: .refusalPromotedToStandingItem).count == 1)
        #expect(third.record.state == .open)

        let event = try #require(try journal.events(ofType: .refusalPromotedToStandingItem).first)
        guard case .refusalPromotedToStandingItem(let name, let count, let bound) = event.event else {
            Issue.record("expected refusalPromotedToStandingItem")
            return
        }
        #expect(name == "FEAT-1")
        #expect(count == 2)
        #expect(bound == 1)

        let standing = try journal.standingRefusals()
        #expect(standing.map(\.featureName) == ["FEAT-1"])
    }

    @Test("A clean run's reset leaves the next Refusal row unpromoted")
    func resetLeavesNextRowUnpromoted() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let (night1, run1) = try openRefusalTestNight(journal, nightStart: "2026-09-15")

        _ = try journal.recordRefusal(feature: feature, content: "thin", consecutiveRefusalsMax: 1, nightID: night1)
        let (night2, run2) = try openRefusalTestNight(journal, nightStart: "2026-09-16", previous: run1)
        let promoted = try journal.recordRefusal(
            feature: feature, content: "still thin", consecutiveRefusalsMax: 1, nightID: night2
        )
        #expect(promoted.record.standingItemNightID != nil)
        #expect(try journal.standingRefusals().count == 1)

        try journal.resetConsecutiveRefusals(feature: feature, nightID: night2)

        let (night3, _) = try openRefusalTestNight(journal, nightStart: "2026-09-17", previous: run2)
        let fresh = try journal.recordRefusal(
            feature: feature, content: "thin once more", consecutiveRefusalsMax: 1, nightID: night3
        )
        #expect(fresh.newlyOpened)
        #expect(fresh.record.consecutiveRefusals == 1)
        #expect(fresh.record.standingItemNightID == nil)
        // The closed, already-promoted row is no longer live: standingRefusals only returns the fresh one
        // once it, too, is promoted — here it is not.
        #expect(try journal.standingRefusals().isEmpty)
    }
}
