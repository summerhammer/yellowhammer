import Domain
import Foundation
import Testing

@testable import Journal

// OQ191 items 2, 5, 6 and 9 (landing/open-one-pull-request-per-repository#unpublished-commits-pin): the
// "not published" report's two Journal events round-trip, a HEAD that descends with its commit count and one that
// does not without it.
@Suite("Unpublished commits events")
struct UnpublishedCommitsEventTests {
    private static let recorded = "fedcba9876543210fedcba9876543210fedcba98"
    private static let head = "0123456789abcdef0123456789abcdef01234567"

    private func openJournal(_ directory: URL) throws -> JournalStore {
        try JournalStore.open(
            configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
        )
    }

    @Test(
        "unpublishedCommitsReported round-trips a HEAD after the recorded commit and one that differs",
        arguments: [3, nil] as [Int?]
    )
    func reportedRoundTrips(commitsAfter: Int?) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try openJournal(directory)
        let event = JournalEvent.unpublishedCommitsReported(
            cycleID: 7,
            unpublished: UnpublishedHead(
                repository: "backend", recordedCommit: Self.recorded, head: Self.head, commitsAfter: commitsAfter,
                noPushedBranch: false
            )
        )

        try journal.append(event, act: .land, runID: RunID())

        let records = try journal.events(ofType: .unpublishedCommitsReported)
        #expect(records.map(\.event) == [event])
        #expect(records.first?.type.rawValue == "UnpublishedCommitsReported")
        #expect(event.payload?["descends"] == (commitsAfter == nil ? "false" : "true"))
        #expect(event.payload?["commits_after"] == commitsAfter.map(String.init))
    }

    @Test("unpublishedCommitsPinned round-trips the pin ref and the no-pushed-branch mark")
    func pinnedRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try openJournal(directory)
        let event = JournalEvent.unpublishedCommitsPinned(
            cycleID: 7,
            unpublished: UnpublishedHead(
                repository: "mobile", recordedCommit: Self.recorded, head: Self.head, commitsAfter: 1,
                noPushedBranch: true
            ),
            pinRef: "refs/yellowhammer/unpublished/yh-proj-feat"
        )

        try journal.append(event, act: .land, runID: RunID())

        let records = try journal.events(ofType: .unpublishedCommitsPinned)
        #expect(records.map(\.event) == [event])
        #expect(records.first?.type.rawValue == "UnpublishedCommitsPinned")
        #expect(event.payload?["pin_ref"] == "refs/yellowhammer/unpublished/yh-proj-feat")
    }
}
