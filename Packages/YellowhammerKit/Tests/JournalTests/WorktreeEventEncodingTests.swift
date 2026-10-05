import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Split out of EventEncodingTests.swift to keep that file under the length limit. Round-trips the five
// events WorktreeReconciler appends (loop-state/reconcile-worktrees-at-act-start).

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

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("worktreeLost event round-trips")
func worktreeLostRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeLost(
            featureID: 1, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1", pinnedCommit: "abc123"
        ),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard
        case .worktreeLost(let featureID, let repository, let worktreeID, let path, let pinnedCommit) =
        records[0].event
    else {
        Issue.record("Event is not worktreeLost")
        return
    }
    #expect(featureID == 1)
    #expect(repository == "backend")
    #expect(worktreeID == "wt-1")
    #expect(path == "/tmp/wt-1")
    #expect(pinnedCommit == "abc123")
}

@Test("worktreeFenced event round-trips")
func worktreeFencedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeFenced(featureID: 2, repository: "backend", path: "/tmp/wt-2", killed: 3),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .worktreeFenced(let featureID, let repository, let path, let killed) = records[0].event else {
        Issue.record("Event is not worktreeFenced")
        return
    }
    #expect(featureID == 2)
    #expect(repository == "backend")
    #expect(path == "/tmp/wt-2")
    #expect(killed == 3)
}

@Test("worktreeNotQuiescent event round-trips")
func worktreeNotQuiescentRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeNotQuiescent(featureID: 3, repository: "mobile", path: "/tmp/wt-3", remaining: 2),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .worktreeNotQuiescent(let featureID, let repository, let path, let remaining) = records[0].event else {
        Issue.record("Event is not worktreeNotQuiescent")
        return
    }
    #expect(featureID == 3)
    #expect(repository == "mobile")
    #expect(path == "/tmp/wt-3")
    #expect(remaining == 2)
}

@Test("worktreeWIPCommitted event round-trips, with reset_to omitted when nil")
func worktreeWIPCommittedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeWIPCommitted(
            featureID: 4, repository: "backend", wipCommit: "deadbeef",
            wipRef: "refs/yellowhammer/wip/yh-proj-feat", resetTo: "cafef00d"
        ),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .worktreeWIPCommitted(let featureID, let repository, let wipCommit, let wipRef, let resetTo) =
        records[0].event
    else {
        Issue.record("Event is not worktreeWIPCommitted")
        return
    }
    #expect(featureID == 4)
    #expect(repository == "backend")
    #expect(wipCommit == "deadbeef")
    #expect(wipRef == "refs/yellowhammer/wip/yh-proj-feat")
    #expect(resetTo == "cafef00d")

    let fixture2 = try JournalFixture()
    let journal2 = try fixture2.open()
    try journal2.append(
        .worktreeWIPCommitted(
            featureID: 4, repository: "backend", wipCommit: "deadbeef",
            wipRef: "refs/yellowhammer/wip/yh-proj-feat", resetTo: nil
        ),
        act: .build, runID: run, now: epoch
    )
    let payload = try journal2.read { try String.fetchOne($0, sql: "SELECT payload FROM event WHERE id = 1") }
    #expect(payload?.contains("reset_to") == false)
    let records2 = try journal2.events()
    guard case .worktreeWIPCommitted(_, _, _, _, let resetTo2) = records2[0].event else {
        Issue.record("Event is not worktreeWIPCommitted")
        return
    }
    #expect(resetTo2 == nil)
}

@Test("worktreeReconciliationFailed event round-trips")
func worktreeReconciliationFailedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeReconciliationFailed(
            featureID: 5, repository: "backend", path: "/tmp/wt-5", reason: "git reset exited 1"
        ),
        act: .build, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .worktreeReconciliationFailed(let featureID, let repository, let path, let reason) =
        records[0].event
    else {
        Issue.record("Event is not worktreeReconciliationFailed")
        return
    }
    #expect(featureID == 5)
    #expect(repository == "backend")
    #expect(path == "/tmp/wt-5")
    #expect(reason == "git reset exited 1")
}
