import Domain
import Journal

// A Managed Block rewrite that cannot be written is refused the same way whatever the cause: the entry is
// aborted, a Journal event of its own is appended, the Operator is told on the issue through the Outbox under
// a key derived from the aborted entry (so a repeated abort of the same write posts one comment), and the
// description is left untouched.

extension Outbox {
    /// The delimiters of the issue's description could not be located.
    func abortUnfenced(
        _ entry: OutboxEntry, write: BoardWrite, failure: ManagedBlockFence.Failure
    ) async throws -> OutboxDelivery {
        guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
        let reason = "Managed Block delimiters broken: \(failure)"
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, now: clock())
        try append(.managedBlockDelimiterBroken(issueID: issue.rawValue))
        let diagnostic = try accept(OutboxWrite(
            key: "diagnostic:managed-block:\(entry.clientID.uuidString.lowercased())",
            write: .createComment(issue: issue, body: Self.diagnosticComment(for: failure)),
            cardID: entry.cardID
        ))
        if diagnostic.state == .pending {
            _ = try await deliver(diagnostic)
        }
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }

    /// No rendering offered fits the description budget.
    func abortOverBudget(
        _ entry: OutboxEntry, write: BoardWrite, length: Int, budget: DescriptionBudget, renderingAloneFits: Bool
    ) async throws -> OutboxDelivery {
        guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
        let unit = budget.limit.unit.plural
        let reason = "the description would be \(length) \(unit) long, over its budget of \(budget.value)"
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, now: clock())
        try append(.managedBlockOverBudget(issueID: issue.rawValue, length: length, budget: budget.value))
        let diagnostic = try accept(OutboxWrite(
            key: "diagnostic:managed-block-over-budget:\(entry.clientID.uuidString.lowercased())",
            write: .createComment(
                issue: issue,
                body: Self.overBudgetComment(length: length, budget: budget, renderingAloneFits: renderingAloneFits)
            ),
            cardID: entry.cardID
        ))
        if diagnostic.state == .pending {
            _ = try await deliver(diagnostic)
        }
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }

    /// Names the composed size, the budget and its unit, and the likely cause: a Managed Block that cannot
    /// fit on its own points at a lowered budget or a longer Route id; otherwise the Operator's text does.
    static func overBudgetComment(length: Int, budget: DescriptionBudget, renderingAloneFits: Bool) -> String {
        let unit = budget.limit.unit.plural
        let cause = renderingAloneFits
            ? "The text that takes the room is the Operator's: the prose outside the Managed Block, or the "
                + "Architectural Brief, Definition of Done and references inside it."
            : "Even the most compacted Managed Block does not fit on its own, so the likely cause is a "
                + "description budget lowered after the Card was written, a longer Route id, or the Operator's "
                + "own text inside the Managed Block."
        return """
        Yellowhammer could not update this issue's Managed Block: the whole description would be \(length) \
        \(unit) long, over the description budget of \(budget.value) \(unit), even with the Managed Block \
        compacted. The description was left untouched. \(cause)
        """
    }

    static func diagnosticComment(for failure: ManagedBlockFence.Failure) -> String {
        """
        Yellowhammer could not update this issue's Managed Block: \(failure). The description was left \
        untouched. Restore the `\(ManagedBlockFence.start)` and `\(ManagedBlockFence.end)` delimiters, \
        on their own lines with the block between them, and updates resume on the next Act.
        """
    }
}
