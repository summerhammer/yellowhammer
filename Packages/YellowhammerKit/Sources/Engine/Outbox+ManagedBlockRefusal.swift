import Domain
import Journal

// A Managed Block rewrite that cannot be written is refused the same way whatever the cause: the entry is
// aborted, a Journal event of its own is appended, the Operator is told on the issue through the Outbox under
// a key derived from the aborted entry (so a repeated abort of the same write posts one comment), and the
// description is left untouched.

extension Outbox {
    /// What the refusal of an over-budget write is attributed to (issue #670).
    enum OverBudgetCause: Equatable {
        /// A whole Managed Block, or a Feature's authored prose; `renderingAloneFits` says whether the most
        /// compacted block would fit with none of the issue's other text.
        case blockRewrite(renderingAloneFits: Bool)
        /// The Roll-up, Verification and preserved Mainline merge-test reports are measured together.
        case featureRollUp(renderingAloneFits: Bool)
        /// A targeted report, whose lines all start `prefix`; `reportAloneFits` says whether the most
        /// compacted report would fit with none of the issue's other text.
        case lineUpdate(prefix: String, reportAloneFits: Bool)
    }

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
        _ entry: OutboxEntry, write: BoardWrite, length: Int, budget: DescriptionBudget, cause: OverBudgetCause
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
                body: Self.overBudgetComment(length: length, budget: budget, cause: cause)
            ),
            cardID: entry.cardID
        ))
        if diagnostic.state == .pending {
            _ = try await deliver(diagnostic)
        }
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }

    /// Names the composed size, the budget and its unit, and the likely cause. A whole Managed Block that
    /// cannot fit on its own points at a lowered budget or a longer Route id; otherwise the Operator's text
    /// does. A targeted report is named by its prefix and is never blamed on either: Yellowhammer wrote it
    /// (issue #670).
    static func overBudgetComment(length: Int, budget: DescriptionBudget, cause: OverBudgetCause) -> String {
        let unit = budget.limit.unit.plural
        switch cause {
        case .blockRewrite(let renderingAloneFits):
            let reason = renderingAloneFits
                ? "The text that takes the room is the Operator's: the prose outside the Managed Block, or the "
                    + "Architectural Brief, Definition of Done and references inside it."
                : "Even the most compacted Managed Block does not fit on its own, so the likely cause is a "
                    + "description budget lowered after the Card was written, a longer Route id, or the "
                    + "Operator's own text inside the Managed Block."
            return """
            Yellowhammer could not update this issue's Managed Block: the whole description would be \(length) \
            \(unit) long, over the description budget of \(budget.value) \(unit), even with the Managed Block \
            compacted. The description was left untouched. \(reason)
            """
        case .featureRollUp(let renderingAloneFits):
            let reason = renderingAloneFits
                ? "The Roll-up and reports fit on their own; "
                    + "the prose outside the Managed Block leaves too little room."
                : "The Roll-up and reports together are longer than the budget even on their own."
            return """
            Yellowhammer could not update this Feature's Roll-up and reports: the whole description would be \
            \(length) \(unit) long, over the description budget of \(budget.value) \(unit), after trying every \
            available Verification compaction. The description was left untouched. \(reason) Any full Verification \
            report stays in the Journal. Raise the Board Connection's description budget in \
            Settings › Board connections.
            """
        case .lineUpdate(let prefix, let reportAloneFits):
            let reason = reportAloneFits
                ? "The report fits the budget on its own, so the rest of the description (the Operator's text, "
                    + "or the Managed Block's other lines) leaves too little room for it."
                : "The report itself is longer than the budget: raising the Board Connection's description "
                    + "budget in Settings › Board connections would let it fit."
            return """
            Yellowhammer could not write the report on the lines starting `\(prefix)` into this issue's \
            Managed Block: the whole description would be \(length) \(unit) long, over the description budget \
            of \(budget.value) \(unit), even with the report compacted to its shortest form. The description \
            was left untouched. \(reason) The full report stays in the Journal.
            """
        }
    }

    static func diagnosticComment(for failure: ManagedBlockFence.Failure) -> String {
        if failure == .transcriptionDelimiterUnpaired {
            return """
            Yellowhammer could not update this issue's Managed Block: \(failure). The description was left \
            untouched. Restore the missing `\(TranscriptionBlockLine.startPrefix)…-->` or \
            `\(TranscriptionBlockLine.endMarker)` delimiter, or delete the whole Transcription Block (both \
            delimiters and its `Contract:` line), and updates resume on the next Act.
            """
        }
        return """
        Yellowhammer could not update this issue's Managed Block: \(failure). The description was left \
        untouched. Restore the `\(ManagedBlockFence.start)` and `\(ManagedBlockFence.end)` delimiters, \
        on their own lines with the block between them, and updates resume on the next Act.
        """
    }
}
