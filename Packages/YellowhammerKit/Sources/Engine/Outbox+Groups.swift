import Domain
import Foundation
import Journal

extension Outbox {

    /// Undoes what a group already applied, through the Outbox: every created issue is archived and
    /// every update with an `undo` is reverted; the group's remaining pending writes are aborted.
    func rollBack(groupID: String, reason: String) async throws -> [OutboxDelivery] {
        var compensations: [OutboxWrite] = []
        for entry in try journal.outboxEntries(groupID: groupID) {
            switch entry.state {
            case .pending:
                _ = try journal.markOutboxAborted(id: entry.id, reason: "group rolled back: \(reason)", now: clock())
            case .applied:
                let write = try? JSONDecoder().decode(BoardWrite.self, from: Data(entry.payload.utf8))
                let key = "rollback:\(groupID):\(entry.clientID.uuidString.lowercased())"
                switch write {
                case .createIssue?:
                    if let created = entry.result {
                        let issue = BoardObjectID(rawValue: created)
                        compensations.append(
                            OutboxWrite(key: key, write: .archiveIssue(issue: issue), cardID: entry.cardID)
                        )
                    }
                case .updateIssue(let issue, _, let undo?)?:
                    compensations.append(OutboxWrite(
                        key: key, write: .updateIssue(issue: issue, change: undo, undo: nil), cardID: entry.cardID
                    ))
                default:
                    break
                }
            case .failed, .aborted:
                break
            }
        }
        try append(.outboxGroupRolledBack(groupID: groupID, reason: reason))

        var deliveries: [OutboxDelivery] = []
        for entry in try accept(compensations) where entry.state == .pending {
            deliveries.append(try await deliver(entry))
        }
        return deliveries
    }
}
