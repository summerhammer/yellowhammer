import Domain
import Foundation
import Journal

// Recording what the board did, once the Outbox has told it (split out of Outbox.swift to keep that file
// under the length limit).

extension Outbox {
    func record(
        _ performed: Performed, for entry: OutboxEntry, write: BoardWrite
    ) async throws -> OutboxDelivery {
        let now = clock()
        switch performed {
        case .created(let receipt):
            let applied = try journal.markOutboxApplied(id: entry.id, result: receipt.id.rawValue, now: now)
            try recordBaseline(of: write, created: receipt.id, now: now)
            switch receipt {
            case .created(let id):
                return OutboxDelivery(entry: applied, outcome: .applied(id))
            case .alreadyApplied(let id):
                return OutboxDelivery(entry: applied, outcome: .alreadyApplied(id))
            }
        case .updated:
            let applied = try journal.markOutboxApplied(id: entry.id, result: nil, now: now)
            return OutboxDelivery(entry: applied, outcome: .applied(nil))
        case .fenced(let replacement, let renderedHash):
            guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
            let applied = try journal.markOutboxApplied(id: entry.id, result: nil, now: now)
            try journal.recordManagedBlockPosted(issueID: issue.rawValue, hash: renderedHash, now: now)
            try append(.managedBlockWritten(
                issueID: issue.rawValue, preservedProseHash: replacement.preservedProseHash, renderedHash: renderedHash
            ))
            return OutboxDelivery(entry: applied, outcome: .applied(nil))
        case .unfenced(let failure):
            return try await abortUnfenced(entry, write: write, failure: failure)
        case .inputImported(let fields):
            return try supersedeForImport(entry, write: write, fields: fields)
        case .inputInvalid(_, let reason, let blockHash):
            return try await abortInputInvalid(entry, write: write, reason: reason, blockHash: blockHash)
        case .overBudget(let length, let budget, let renderingAloneFits):
            return try await abortOverBudget(
                entry, write: write, length: length, budget: budget, renderingAloneFits: renderingAloneFits
            )
        }
    }

    /// A created issue's Managed Block is the baseline an Operator's later edit is told apart from: without a
    /// record of what Yellowhammer wrote there, an edit cannot be told from the block as it was authored.
    private func recordBaseline(of write: BoardWrite, created id: BoardObjectID, now: Date) throws {
        guard case .createIssue(let draft, _) = write,
              case .success(let parts) = ManagedBlockFence.parts(of: draft.description) else { return }
        try journal.recordManagedBlockPosted(issueID: id.rawValue, hash: parts.blockHash, now: now)
    }
}
