import Domain
import Journal

// Importing a human's input before the Managed Block is rendered again (roadmap P22.4; spec:
// board-projection / write-board-updates-through-the-outbox, "fresh description input inside managed
// markers is preserved before output is regenerated"; maintain-the-managed-block, field ownership).
//
// A full Managed Block rewrite carries a rendering built from the Journal *before* the pre-flight read. If
// the description just read holds an edit to scope, the Architectural Brief or the Definition of Done that
// the Journal has not seen — the Operator saved between the Act's Delta Read and now, or no Readiness Check
// folded it — replacing the block with that rendering would erase it. So the rewrite imports first. When
// the import changed the Journal the rendering is stale and the write is superseded: the caller renders
// again from the Journal and posts that. When an edit cannot be read, the block is left exactly as the
// human wrote it and one comment per revision says why.

extension Outbox {
    /// Nil when the rewrite may go ahead; otherwise the reason it must not, with the Journal already updated.
    func importFreshInput(
        from snapshot: BoardDescriptionSnapshot, issue: BoardObjectID, renderings: [String]
    ) throws -> Performed? {
        guard case .success(let parts) = ManagedBlockFence.parts(of: snapshot.description),
              let card = try journal.card(issueID: issue.rawValue) else { return nil }
        // The board already holds exactly what would be written, or what Yellowhammer itself last wrote: no
        // human edit to read. (Edits to output-only text — Attempts history, roll-up — surface here as a
        // different hash, parse to the Journal's own inputs, and are regenerated from the Journal below.)
        if renderings.contains(parts.block) { return nil }
        // Without a record of what Yellowhammer last wrote there is nothing to tell an edit from the block as it
        // was authored, and reading the whole block as the Operator's would delete whatever the Journal holds
        // that the block does not repeat. An authored Card has that record from its create (see `record`).
        guard let posted = try journal.managedBlockLastPostedHash(issueID: issue.rawValue),
              posted != parts.blockHash else { return nil }

        let parsed = CardManagedBlockParser.parse(block: parts.block)
        let imported = try CardInputReconciler(journal: journal, act: act, runID: runID, nightID: nightID)
            .reconcile(parsed: parsed, card: card)
        if let first = imported.invalid.first {
            let reasons = imported.invalid.map { "\($0.field): \($0.reason)" }.joined(separator: "; ")
            return .inputInvalid(field: first.field, reason: reasons, blockHash: parts.blockHash)
        }
        return imported.changedAnything ? .inputImported(fields: imported.fields) : nil
    }

    /// The Journal now holds the human's edit, so the rendering offered is stale: it is not sent.
    func supersedeForImport(_ entry: OutboxEntry, write: BoardWrite, fields: [String]) throws -> OutboxDelivery {
        guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
        let list = fields.joined(separator: ", ")
        let reason = "the description holds an edit to the Card's \(list) that the Journal had not seen; it was "
            + "imported, and the Managed Block is rendered again from the Journal"
        let superseded = try journal.markOutboxSuperseded(id: entry.id, reason: reason)
        try append(.managedBlockInputImported(issueID: issue.rawValue, fields: list))
        return OutboxDelivery(entry: superseded, outcome: .superseded(reason: reason))
    }

    /// An input the human edited cannot be read: the description is left untouched, the rewrite is aborted, and
    /// the Operator is told once per revision of the block (the comment's key names the revision's hash).
    func abortInputInvalid(
        _ entry: OutboxEntry, write: BoardWrite, reason: String, blockHash: String
    ) async throws -> OutboxDelivery {
        guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
        let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, now: clock())
        try append(.managedBlockInputInvalid(issueID: issue.rawValue, reason: reason))
        let diagnostic = try accept(OutboxWrite(
            key: "diagnostic:managed-block-input:\(issue.rawValue):\(blockHash)",
            write: .createComment(
                issue: issue, body: Self.inputInvalidComment(reason: reason, isFeature: write.isFeatureAuthoring)
            ),
            cardID: entry.cardID
        ))
        if diagnostic.state == .pending {
            _ = try await deliver(diagnostic)
        }
        return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
    }

    static func inputInvalidComment(reason: String, isFeature: Bool) -> String {
        if isFeature {
            return """
            Yellowhammer did not re-author this Feature's brief and Definition of Done: they were edited here \
            since it last wrote them, so it left your text exactly as you saved it (\(reason)). Delete the \
            edit to let the re-authored text in.
            """
        }
        return """
        Yellowhammer could not read your edit to this Card's Managed Block, so it left the description exactly \
        as you saved it and did not replace it with the earlier authored text: \(reason). Correct it and \
        updates resume on the next Act. Until then the Card is not Ready to run.
        """
    }
}
