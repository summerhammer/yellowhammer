import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

let epoch = Date(timeIntervalSince1970: 1_800_000_000)
let nightStart = NightStart(rawValue: "2026-09-29")!  // swiftlint:disable:this force_unwrapping

struct FixtureFeature {
    let featureID: Int64
    let cycleID: Int64
}

func insertFeature(_ journal: JournalStore, issueID: String) throws -> FixtureFeature {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return FixtureFeature(featureID: featureID, cycleID: db.lastInsertedRowID)
    }
}

@discardableResult
func insertCard(
    _ journal: JournalStore,
    cycleID: Int64,
    issueID: String,
    repository: String = "main",
    state: CardState = .todo,
    blockReason: BlockReason? = nil,
    order: Int = 1
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", order, state.rawValue, blockReason?.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

func route() throws -> Route {
    try #require(Route(cli: "claude", model: "sonnet", effort: "medium"))
}
