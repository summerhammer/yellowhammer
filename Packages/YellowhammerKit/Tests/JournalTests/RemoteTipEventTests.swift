import Domain
import Foundation
import Testing

@testable import Journal

// OQ191 item 4 (landing/open-one-pull-request-per-repository#remote-tip-check): the remote tip check's two
// Journal events round-trip, an absent remote Feature Branch as `absent`.
@Suite("Remote tip check events")
struct RemoteTipEventTests {
    @Test(
        "remoteTipMismatch round-trips a remote commit and an absent branch",
        arguments: ["0123456789abcdef0123456789abcdef01234567", nil] as [String?]
    )
    func mismatchRoundTrips(remoteCommit: String?) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JournalStore.open(
            configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
        )
        let event = JournalEvent.remoteTipMismatch(
            repository: "backend", pushedTip: "fedcba9876543210fedcba9876543210fedcba98", remoteCommit: remoteCommit
        )

        try journal.append(event, act: .land, runID: RunID())

        let records = try journal.events(ofType: .remoteTipMismatch)
        #expect(records.map(\.event) == [event])
        #expect(records.first?.type.rawValue == "RemoteTipMismatch")
        #expect(event.payload?["remote_commit"] == remoteCommit ?? "absent")
    }

    @Test("remoteTipUnreadable round-trips its repository and reason")
    func unreadableRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JournalStore.open(
            configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
        )
        let event = JournalEvent.remoteTipUnreadable(repository: "backend", reason: "fatal: repository not found")

        try journal.append(event, act: .land, runID: RunID())

        let records = try journal.events(ofType: .remoteTipUnreadable)
        #expect(records.map(\.event) == [event])
        #expect(records.first?.type.rawValue == "RemoteTipUnreadable")
    }
}
