import Domain
import Journal

extension Outbox {
    /// Archive is itself an intentional mutation. Every other write validates its issue both before
    /// sending and before recording delivery, including creates recovered by idempotent replay.
    func archivedTarget(_ write: BoardWrite, performed: Performed? = nil) async throws -> BoardObjectID? {
        guard let reading else { return nil }
        if case .archiveIssue = write { return nil }
        var issue = write.issueID
        if case .createIssue = write, case .created(let receipt)? = performed { issue = receipt.id }
        guard let issue, let object = try await reading.issue(issue), object.archivedAt != nil else { return nil }
        return issue
    }

    func abortArchived(_ entry: OutboxEntry, issue: BoardObjectID, result: String? = nil) throws -> OutboxDelivery {
        let reason = "issue \(issue.rawValue) is archived; the write was not delivered"
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, result: result, now: clock())
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }
}
