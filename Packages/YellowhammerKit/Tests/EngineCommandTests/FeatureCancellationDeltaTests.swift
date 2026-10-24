import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Author Delta Read of cancellation in the Unmerged Feature Stack")
struct FeatureCancellationDeltaTests {
    @Test("Every page contributes archived Feature status; the latest revision survives reopening the Journal")
    func pagedAuthorReadTracksEveryFeature() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let issueIDs = ["canceled", "completed", "started"]
        for issueID in issueIDs {
            try insertGateFeature(
                journal, issueID: issueID, branch: "yh-\(issueID)", repositories: ["backend"], landed: true
            )
        }
        let before = try journal.unmergedFeatureStack().map(\.feature.id)
        let completed = BoardWorkflowState(id: BoardObjectID(rawValue: "s-completed"),
                                           name: "Done", category: .completed)
        let started = BoardWorkflowState(id: BoardObjectID(rawValue: "s-started"),
                                         name: "In Progress", category: .started)
        let board = FakeReadingBoard([
            page(objects: [object("canceled", state: started, updatedAt: 10)],
                 nextObjectCursor: BoardCursor(rawValue: "page-2")),
            page(objects: [object("completed", state: completed, updatedAt: 11)],
                 nextObjectCursor: BoardCursor(rawValue: "page-3")),
            page(objects: [
                object("started", state: started, updatedAt: 12),
                object("canceled", state: stateCanceledByCategory, updatedAt: 13)
            ])
        ])
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(
            act: .author, runID: runID, mode: .rehearsal, now: outboxEpoch
        ) else {
            Issue.record("expected the author Act Lease")
            return
        }
        let read = DeltaRead(
            journal: journal, board: board, runID: runID, act: .author,
            clock: { outboxEpoch }, horizon: { .distantFuture }
        )
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a complete author Delta Read")
            return
        }
        #expect(report.requests == 3)
        #expect(report.unknownObjects.isEmpty)
        #expect(await board.calls.map(\.objectsAfter) == [
            nil, BoardCursor(rawValue: "page-2"), BoardCursor(rawValue: "page-3")
        ])

        let reopened = try fixture.open()
        let observed = try issueIDs.map { try reopened.featureBoardObservation(issueID: $0)?.workflowState }
        #expect(observed == [stateCanceledByCategory, completed, started])
        #expect(try reopened.featureBoardObservation(issueID: "canceled")?.updatedAt
            == deltaEpoch.addingTimeInterval(13))
        #expect(try reopened.unmergedFeatureStack().map(\.feature.id) == before)
        #expect(try reopened.pendingOutboxEntries().isEmpty, "observing disposition writes no Board change")
    }
}
