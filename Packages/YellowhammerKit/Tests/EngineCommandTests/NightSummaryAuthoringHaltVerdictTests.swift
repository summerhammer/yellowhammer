import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// morning-report/write-the-night-summary: decisions come from unresolved board Cards in this
// Project's Journal, including the Feature Card an Authoring Halt leaves before a Cycle exists.
private struct AuthoringHaltVerdictFixture: ~Copyable {
    let fixture: NightCardJournalFixture
    let journal: JournalStore

    init() throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        self.fixture = fixture
        self.journal = journal
    }

    func night(_ date: String) throws -> NightRecord {
        let nightStart = try #require(NightStart(rawValue: date))
        let id = try journal.write { db in
            try db.execute(
                sql: "INSERT INTO night (project_id, night_start, mode, state, opened_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [fixture.projectID.rawValue, date, "real", "closed", JournalStore.timestamp(Date())]
            )
            return db.lastInsertedRowID
        }
        return try #require(try journal.night(id: id), "Missing fixture Night \(nightStart)")
    }

    @discardableResult
    func halt(_ name: String, issueID: String? = nil, night: NightRecord) throws -> FeatureName {
        let feature = try #require(FeatureName(rawValue: name))
        try journal.recordAuthoringHalt(
            feature: feature, causeKind: "transcription", content: "A repository seam needs attention",
            nightID: night.id
        )
        if let issueID {
            try journal.recordAuthoringHaltIssue(feature: feature, issueID: issueID)
        }
        return feature
    }

    func landedCycleWithWaitingCard() throws -> Int64 {
        try journal.write { db in
            let timestamp = JournalStore.timestamp(Date())
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: ["LANDED-1", "selected", timestamp]
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
                arguments: [cycleID, "WORK-1", "backend", "card", 1, CardState.waitingOnYou.rawValue, 0, timestamp]
            )
            return cycleID
        }
    }
}

@Suite("Night Summary: Authoring Halt decisions (#439)")
struct NightSummaryAuthoringHaltVerdictTests {
    @Test("A pre-Cycle Feature Card counts once across repeated halts and cleared history")
    func unresolvedFeatureCardCountsOnce() throws {
        let rig = try AuthoringHaltVerdictFixture()
        let night = try rig.night("2026-10-08")
        let feature = try rig.halt("FEATURE-1", issueID: "FEAT-1", night: night)
        try rig.halt("FEATURE-1", issueID: "FEAT-1", night: night)
        #expect(try rig.journal.inFlightCycleID() == nil)
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "1 decision waiting · did not advance — quiet · closed"
        )

        try rig.journal.clearAuthoringHalts(feature: feature, nightID: night.id)
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "no decisions waiting · did not advance — quiet · closed"
        )
        try rig.halt("FEATURE-1", issueID: "FEAT-1", night: night)
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "1 decision waiting · did not advance — quiet · closed"
        )
    }

    @Test("An expired halt stays a decision on later quiet Nights until cleared")
    func expiredHaltPersistsAcrossNights() throws {
        let rig = try AuthoringHaltVerdictFixture()
        let opening = try rig.night("2026-10-08")
        let feature = try rig.halt("FEATURE-1", issueID: "FEAT-1", night: opening)
        let expiry = try rig.night("2026-10-09")
        try rig.journal.advanceAuthoringHaltClocks(nightID: expiry.id, unansweredNightsMax: 0)
        let later = try rig.night("2026-10-10")
        try rig.journal.append(
            .authoringPredecessorNotLanded(featureIssueID: "FEATURE-2", repositories: ["backend"]), nightID: later.id
        )
        #expect(try rig.journal.events(ofType: .authoringHaltOpened).allSatisfy { $0.nightID != later.id })
        #expect(
            try NightSummary.verdictLine(night: later, journal: rig.journal)
                == "1 decision waiting · did not advance — quiet · closed"
        )
        try rig.journal.clearAuthoringHalts(feature: feature, nightID: later.id)
        #expect(
            try NightSummary.verdictLine(night: later, journal: rig.journal)
                == "no decisions waiting · did not advance — quiet · closed"
        )
    }

    @Test("Halts without a board Card and rolled-back authoring faults do not count")
    func unpublishedHaltsDoNotCount() throws {
        let rig = try AuthoringHaltVerdictFixture()
        let night = try rig.night("2026-10-08")
        try rig.halt("UNPUBLISHED", night: night)
        try rig.journal.append(
            .featureAuthoringFailed(name: "ROLLED-BACK", groupKey: "rollback-fixture", reason: "board write failed"),
            nightID: night.id
        )
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "no decisions waiting · did not advance — quiet · closed"
        )
    }

    @Test("Distinct halted Feature Cards combine with Cycle holes and preserve the in-flight Feature suffix")
    func haltedFeaturesCombineWithCycleHoles() throws {
        let rig = try AuthoringHaltVerdictFixture()
        let night = try rig.night("2026-10-08")
        try rig.halt("FEATURE-1", issueID: "FEAT-1", night: night)
        try rig.halt("FEATURE-2", issueID: "FEAT-2", night: night)
        // Multiple halt records referring to one board Card still represent one decision.
        try rig.halt("FEATURE-1-RENAMED", issueID: "FEAT-1", night: night)
        let cycleID = try rig.landedCycleWithWaitingCard()
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "3 decisions waiting · did not advance — quiet · closed"
        )
        try rig.journal.write { db in
            try db.execute(
                sql: "UPDATE cycle SET landed_at = ? WHERE id = ?",
                arguments: [JournalStore.timestamp(Date()), cycleID]
            )
        }
        #expect(
            try NightSummary.verdictLine(night: night, journal: rig.journal)
                == "3 decisions waiting, Feature `LANDED-1` in flight · did not advance — quiet · closed"
        )
    }
}
