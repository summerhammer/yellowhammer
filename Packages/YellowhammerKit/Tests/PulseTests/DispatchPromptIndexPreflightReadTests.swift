import Config
import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

@Suite("DispatchPromptIndex Night read of Route Pre-flight dispatches")
struct PromptIndexPreflightTests {
    private let recordID = "rec-preflight"
    private let route = Route(cli: "claude", model: "sonnet", effort: "medium")!

    /// A Night whose Journal holds the pre-flight's capture event; returns the Night's id.
    private func openNightWithPreflight(
        fixture: borrowing PromptIndexFixture, journal: JournalStore, run: RunID
    ) throws -> Int64 {
        _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch)
        try journal.append(
            .routePreflightPromptCaptureRequested(recordID: recordID, route: route),
            act: .build, runID: run, nightID: opening.night.id, now: epoch
        )
        return opening.night.id
    }

    private func preflightRecord(
        fixture: borrowing PromptIndexFixture, run: RunID, nightID: Int64
    ) -> DispatchPromptRecord {
        let provenance = DispatchProvenance(
            recordID: recordID, family: .routePreflight, projectID: fixture.projectID.rawValue,
            runID: run.rawValue, nightID: nightID
        )
        return DispatchPromptRecord(
            provenance: provenance, route: route.description, pass: .architect, dispatchedAt: epoch,
            defaultVersion: 1, projectInstructions: .absent, session: .new,
            instruction: "This is an automated Yellowhammer probe", outputSchema: nil, launch: .launched
        )
    }

    private func readItem(
        fixture: borrowing PromptIndexFixture, journal: JournalStore, store: DispatchPromptStore,
        nightID: Int64, asOf: Date
    ) throws -> DispatchPromptItem {
        let index = try DispatchPromptIndex.read(
            journal: journal, store: store, projectID: fixture.projectID, scope: .night(nightID: nightID), asOf: asOf
        )
        #expect(index.items.count == 1)
        let item = try #require(index.items.first)
        #expect(item.id == recordID)
        #expect(item.family == .routePreflight)
        #expect(item.nightID == nightID)
        return item
    }

    @Test("An available pre-flight record is listed as recorded, with its text")
    func recordedPreflight() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let run = RunID()
        let nightID = try openNightWithPreflight(fixture: fixture, journal: journal, run: run)
        let record = preflightRecord(fixture: fixture, run: run, nightID: nightID)
        _ = store.capture(record)

        let item = try readItem(
            fixture: fixture, journal: journal, store: store, nightID: nightID, asOf: epoch.addingTimeInterval(60)
        )
        #expect(item.state == .recorded(record))
        #expect(item.instruction == "This is an automated Yellowhammer probe")
    }

    @Test("A deleted pre-flight record stays listed as deleted")
    func deletedPreflight() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let run = RunID()
        let nightID = try openNightWithPreflight(fixture: fixture, journal: journal, run: run)
        let record = preflightRecord(fixture: fixture, run: run, nightID: nightID)
        _ = store.capture(record)
        #expect(store.delete(ids: [recordID], in: record.provenance.scope) == [.deleted])

        let item = try readItem(
            fixture: fixture, journal: journal, store: store, nightID: nightID, asOf: epoch.addingTimeInterval(60)
        )
        guard case .deleted = item.state else {
            Issue.record("expected .deleted, got \(item.state)")
            return
        }
        #expect(item.instruction == nil)
    }

    @Test("A pre-flight whose record file is absent, under 30 days old, is listed as unavailable")
    func unavailablePreflight() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let nightID = try openNightWithPreflight(fixture: fixture, journal: journal, run: RunID())

        let item = try readItem(
            fixture: fixture, journal: journal, store: store, nightID: nightID, asOf: epoch.addingTimeInterval(86_400)
        )
        guard case .unavailable = item.state else {
            Issue.record("expected .unavailable, got \(item.state)")
            return
        }
    }

    @Test("A pre-flight whose record was swept after 30 days is listed as expired")
    func expiredPreflight() throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let nightID = try openNightWithPreflight(fixture: fixture, journal: journal, run: RunID())

        let item = try readItem(
            fixture: fixture, journal: journal, store: store, nightID: nightID,
            asOf: epoch.addingTimeInterval(31 * 86_400)
        )
        guard case .expired = item.state else {
            Issue.record("expected .expired, got \(item.state)")
            return
        }
    }
}
