import Domain
import Foundation
import Testing

@testable import Journal

// OQ196 item 1 (landing/open-one-pull-request-per-repository#uncommitted-snapshot): the snapshot's Journal event
// round-trips at release and at cancellation.
@Suite("Uncommitted snapshot event")
struct UncommittedSnapshotEventTests {
    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("uncommittedChangesSnapshotted round-trips with its counts and moment", arguments: [false, true])
    func roundTrips(atCancellation: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JournalStore.open(
            configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
        )
        let event = JournalEvent.uncommittedChangesSnapshotted(
            cycleID: 7,
            snapshot: UncommittedChangesSnapshot(
                repository: "backend", ref: "refs/yellowhammer/snapshot/yh-proj-feat",
                commit: "0123456789abcdef0123456789abcdef01234567", modified: 2, untracked: 1,
                atCancellation: atCancellation
            )
        )

        try journal.append(event, act: .land, runID: RunID())

        let records = try journal.events(ofType: .uncommittedChangesSnapshotted)
        #expect(records.map(\.event) == [event])
        #expect(records.first?.type.rawValue == "UncommittedChangesSnapshotted")
        #expect(event.payload?["at"] == (atCancellation ? "cancellation" : "release"))
        #expect(event.payload?["modified"] == "2")
        #expect(event.payload?["untracked"] == "1")
        #expect(event.payload?["ref"] == "refs/yellowhammer/snapshot/yh-proj-feat")
    }
}
