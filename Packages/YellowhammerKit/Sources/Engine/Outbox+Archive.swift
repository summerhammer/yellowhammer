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

    /// A removed Card's issue (trashed, or archived while the Card was in play; OQ142) is set aside:
    /// Yellowhammer posts nothing to it, however the write came to be queued. The Journal's own record
    /// answers this, not a board read, so it holds even when the board cannot be reached. A trashed
    /// issue is also archived, which the archived check catches on a live board; this one is the Journal's
    /// side of the same ruling and covers a Card the Delta Read has recorded as removed.
    func removedTarget(_ entry: OutboxEntry) throws -> String? {
        guard let issueID = entry.issueID, let card = try journal.card(issueID: issueID), card.isRemovedFromBoard
        else { return nil }
        return issueID
    }

    func abortRemoved(_ entry: OutboxEntry, issueID: String) throws -> OutboxDelivery {
        let reason = "the Card's issue \(issueID) was removed from the board; the write was not delivered"
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, result: nil, now: clock())
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }

    func abortArchived(_ entry: OutboxEntry, issue: BoardObjectID, result: String? = nil) throws -> OutboxDelivery {
        let reason = "issue \(issue.rawValue) is archived; the write was not delivered"
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, result: result, now: clock())
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }
}
