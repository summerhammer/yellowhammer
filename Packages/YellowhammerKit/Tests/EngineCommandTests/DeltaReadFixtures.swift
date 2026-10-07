import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// Fixtures shared by the Delta Read tests: a run holding the Project's Act-scoped Lease, a fixture
// Card, and board objects and comments as an in-memory Linear stand-in reports them.

let deltaEpoch = outboxEpoch
let humanAuthor = BoardCommentAuthor(id: BoardObjectID(rawValue: "user-max"), name: "Max", isYellowhammer: false)
let stateTodo = BoardWorkflowState(id: BoardObjectID(rawValue: "s-todo"), name: "Todo")
let stateBlocked = BoardWorkflowState(id: BoardObjectID(rawValue: "s-blocked"), name: "Blocked")
let stateShelved = BoardWorkflowState(id: BoardObjectID(rawValue: "s-shelved"), name: "Shelved")
/// A real Linear team's own cancelled state: named `Canceled`, category `.shelved` — not the
/// glossary spelling `Shelved` Yellowhammer provisions, so only the category resolves it.
let stateCanceledByCategory = BoardWorkflowState(
    id: BoardObjectID(rawValue: "s-canceled"), name: "Canceled", category: .shelved
)
let stateWaiting = BoardWorkflowState(id: BoardObjectID(rawValue: "s-waiting"), name: "Waiting on You")

// MARK: - Fixtures

func deltaRead(
    _ journal: JournalStore, board: FakeReadingBoard, repositories: Set<String>? = nil,
    clock: ManualClock = ManualClock(), installation: AppInstallationLabel? = nil
) throws -> (DeltaRead, RunID) {
    let runID = RunID()
    let claim = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: clock.read())
    guard case .claimed = claim else { throw JournalError.actLeaseLost(runID: runID, holder: nil) }
    let read = DeltaRead(
        journal: journal, board: board, runID: runID, act: .build, repositories: repositories,
        installation: installation, clock: clock.read
    )
    return (read, runID)
}

/// Inserts a Feature → Cycle → Card chain and returns the Card's Journal id.
@discardableResult
func insertCard(
    _ journal: JournalStore, issueID: String, state: CardState = .todo, repository: String = "backend",
    title: String? = nil
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(deltaEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(deltaEpoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, title, repository, kind, authored_order, state, budget_epoch,
            created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, title, repository, "impl", 1, state.rawValue, 0, JournalStore.timestamp(deltaEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

func object(
    _ id: String, title: String? = nil, state: BoardWorkflowState, description: String? = nil,
    updatedAt: TimeInterval = 10, archivedAt: TimeInterval? = nil, isTrashed: Bool = false
) -> BoardObject {
    BoardObject(
        id: BoardObjectID(rawValue: id), key: "ENG-\(id)", title: title ?? id, description: description,
        workflowState: state, labels: [], parent: nil, url: "https://linear.app/x/\(id)",
        createdAt: deltaEpoch, updatedAt: deltaEpoch.addingTimeInterval(updatedAt),
        archivedAt: archivedAt.map { deltaEpoch.addingTimeInterval($0) }, isTrashed: isTrashed
    )
}

func comment(
    _ id: String, on issue: String, author: BoardCommentAuthor, parent: String? = nil, createdAt: TimeInterval = 20
) -> BoardComment {
    BoardComment(
        id: BoardObjectID(rawValue: id), issue: BoardObjectID(rawValue: issue), issueKey: "ENG-\(issue)",
        issueWorkflowState: stateWaiting, body: "reply", parent: parent.map(BoardObjectID.init),
        author: author, createdAt: deltaEpoch.addingTimeInterval(createdAt)
    )
}

func fenced(block: String, prose: String = "Operator prose.\n\n") -> String {
    prose + ManagedBlockFence.initialDescription(rendered: block)
}
