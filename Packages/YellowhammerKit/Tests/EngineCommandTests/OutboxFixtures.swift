import Domain
import Foundation
import GRDB
import Synchronization
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox and board-projection/maintain-the-managed-block:
// every board write is accepted into the Project's Journal before it is sent, under a deterministic
// client id; the run's Lease is revalidated immediately before each write; a description is written
// only by a fenced rewrite after a pre-flight read; a permanent failure is recorded for the Night
// Summary; a group leaves all of its writes on the board or none. These run against an in-memory
// Linear stand-in, which is what a rehearsal may assert: Outbox idempotency and replay after a killed run.

struct OutboxJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

let outboxEpoch = Date(timeIntervalSince1970: 1_800_000_000)
let outboxTeam = BoardObjectID(rawValue: "outboxTeam-1")

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let now: Mutex<Date>

    init(_ start: Date = outboxEpoch) {
        now = Mutex(start)
    }

    func advance(by seconds: TimeInterval) {
        now.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var read: @Sendable () -> Date {
        { self.now.withLock { $0 } }
    }
}

struct SimulatedCrash: Error {}

/// A run holding the Project's Act-scoped Lease, with an Outbox bound to it.
func outbox(
    _ journal: JournalStore,
    board: FakeWritingBoard,
    runID: RunID = RunID(),
    clock: ManualClock = ManualClock(),
    installation: AppInstallationLabel? = nil,
    interrupt: @escaping @Sendable (OutboxEntry) throws -> Void = { _ in }
) throws -> Outbox {
    let claim = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: clock.read())
    guard case .claimed = claim else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    return Outbox(
        journal: journal, board: board, runID: runID, act: .build, installation: installation, clock: clock.read,
        interrupt: interrupt
    )
}

/// Inserts a Feature → Cycle → Card chain and returns the Card's Journal id.
func insertFixtureCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(outboxEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(outboxEpoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "main", "card", 1, CardState.todo.rawValue, 0, JournalStore.timestamp(outboxEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

func card(_ title: String, parentKey: String? = nil, description: String? = nil) -> BoardWrite {
    .createIssue(BoardIssueDraft(team: outboxTeam, title: title, description: description), parentKey: parentKey)
}

let fencedDescription = """
    The Operator wrote this above.

    <!-- yh:managed:start -->
    old block
    <!-- yh:managed:end -->

    And this below — with a trailing note.
    """
