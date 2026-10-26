import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

// A route try's ordinal restarts at 1 for every authoring walk and every Feature's verification, so a
// dispatched/rejected event must pair with the capture of its OWN try: the most recent preceding one of the
// same run, pass and ordinal. These tests pin that no try is ever linked to another's record.

@Suite("Prompt capture pairing across Acts and Features")
struct PromptCapturePairingTests {
    private func record(
        _ id: Int64, _ event: JournalEvent, run: RunID?, at offset: TimeInterval
    ) -> JournalEventRecord {
        JournalEventRecord(
            id: id, event: event, act: .land, runID: run, nightID: 1,
            occurredAt: epoch.addingTimeInterval(offset)
        )
    }

    private func capture(_ recordID: String, ordinal: Int?) -> JournalEvent {
        .promptCaptureRequested(
            recordID: recordID, pass: .verifier, cardID: nil, issueID: nil, attemptID: nil, round: nil,
            ordinal: ordinal
        )
    }

    private func dispatched(ordinal: Int) -> JournalEvent {
        .authoringDispatched(pass: .verifier, route: "claude/sonnet/medium", ordinal: ordinal, fixture: nil)
    }

    private func rejected(ordinal: Int) -> JournalEvent {
        .authoringRouteRejected(
            pass: .verifier, route: "claude/sonnet/medium", ordinal: ordinal, cause: .invalidOutput, reason: "bad"
        )
    }

    @Test("One run verifying two Features links each try-1 entry to its own record")
    func twoFeaturesInOneRunLinkTheirOwnRecords() throws {
        let run = RunID()
        let records = [
            record(1, capture("rec-f1", ordinal: 1), run: run, at: 0),
            record(2, rejected(ordinal: 1), run: run, at: 1),
            record(3, capture("rec-f2", ordinal: 1), run: run, at: 2),
            record(4, dispatched(ordinal: 1), run: run, at: 3),
            record(5, rejected(ordinal: 1), run: run, at: 4),
            // A dispatched event whose capture never came pairs with nothing, not with another try.
            record(6, dispatched(ordinal: 2), run: run, at: 5)
        ]

        let runs = NightAccount.ActRun.runs(from: records, cardNames: [:], featureNames: [:])

        let entries = try #require(runs.first).entries
        #expect(entries.map(\.promptDispatchID) == ["rec-f1", "rec-f1", "rec-f2", "rec-f2", "rec-f2", nil])
    }

    @Test("Two author Acts: only the Act whose try-1 was rejected reads rejected")
    func rejectionDoesNotCrossActs() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let runA = RunID()
        let runB = RunID()
        _ = try journal.claimActLease(act: .author, runID: runA, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: runA, now: epoch)
        let nightID = opening.night.id
        for id in ["rec-a", "rec-b"] {
            _ = try fixture.captureRecord(id: id, pass: .selection, routeTry: 1, launch: .launched)
        }

        func append(_ event: JournalEvent, run: RunID, at offset: TimeInterval) throws {
            _ = try journal.append(
                event, act: .author, runID: run, nightID: nightID, now: epoch.addingTimeInterval(offset)
            )
        }
        func selectionCapture(_ recordID: String) -> JournalEvent {
            .promptCaptureRequested(
                recordID: recordID, pass: .selection, cardID: nil, issueID: nil, attemptID: nil, round: nil,
                ordinal: 1
            )
        }
        try append(selectionCapture("rec-a"), run: runA, at: 0)
        try append(
            .authoringRouteRejected(
                pass: .selection, route: "claude/sonnet/medium", ordinal: 1, cause: .invalidOutput, reason: "bad"
            ),
            run: runA, at: 1
        )
        try append(selectionCapture("rec-b"), run: runB, at: 10)
        try append(
            .authoringDispatched(pass: .selection, route: "claude/sonnet/medium", ordinal: 1, fixture: nil),
            run: runB, at: 11
        )

        let index = try DispatchPromptIndex.read(
            journal: journal, store: store, projectID: fixture.projectID,
            scope: .night(nightID: nightID), asOf: epoch.addingTimeInterval(20)
        )

        #expect(try #require(index.items.first { $0.id == "rec-a" }).rejectionCause == .invalidOutput)
        #expect(try #require(index.items.first { $0.id == "rec-b" }).rejectionCause == nil)
    }

    @Test("Only an unavailable rejection labels a pending record not launched")
    func onlyUnavailableMeansNotLaunched() async throws {
        let fixture = PromptIndexFixture()
        let journal = try fixture.openJournal()
        let store = fixture.makeStore()
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
        let nightID = opening.night.id
        struct Try {
            let id: String
            let ordinal: Int
            let cause: AuthoringRouteRejectionCause
        }
        let tries = [
            Try(id: "rec-timeout", ordinal: 1, cause: .timedOut),
            Try(id: "rec-invalid", ordinal: 2, cause: .invalidOutput),
            Try(id: "rec-unavailable", ordinal: 3, cause: .unavailable)
        ]
        for (index, item) in tries.enumerated() {
            _ = try fixture.captureRecord(
                id: item.id, pass: .breakdown, routeTry: item.ordinal, launch: .pending
            )
            let at = epoch.addingTimeInterval(TimeInterval(index * 10))
            _ = try journal.append(
                .promptCaptureRequested(
                    recordID: item.id, pass: .breakdown, cardID: nil, issueID: nil, attemptID: nil, round: nil,
                    ordinal: item.ordinal
                ),
                act: .author, runID: run, nightID: nightID, now: at
            )
            _ = try journal.append(
                .authoringRouteRejected(
                    pass: .breakdown, route: "claude/sonnet/medium", ordinal: item.ordinal, cause: item.cause,
                    reason: "why"
                ),
                act: .author, runID: run, nightID: nightID, now: at.addingTimeInterval(1)
            )
        }

        let index = try DispatchPromptIndex.read(
            journal: journal, store: store, projectID: fixture.projectID,
            scope: .night(nightID: nightID), asOf: epoch.addingTimeInterval(60)
        )

        #expect(try #require(index.items.first { $0.id == "rec-timeout" }).launch == .pending)
        #expect(try #require(index.items.first { $0.id == "rec-invalid" }).launch == .pending)
        let unavailable = try #require(index.items.first { $0.id == "rec-unavailable" }).launch
        guard case .notLaunched = unavailable else {
            Issue.record("expected .notLaunched for an unavailable Route, got \(String(describing: unavailable))")
            return
        }
    }
}
