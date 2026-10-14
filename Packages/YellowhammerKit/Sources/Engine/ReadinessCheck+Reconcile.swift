import Domain
import Foundation
import Journal

/// The Journal plus the event-stamping identity (`act`, `runID`, `nightID`) every reconciliation write
/// appends under — bundled so the reconciliation helpers below stay under the parameter-count limit.
private struct ReconcileContext {
    let journal: JournalStore
    let act: Act
    let runID: RunID
    let nightID: Int64?

    init(_ context: BuildActContext) {
        journal = context.act.journal
        act = context.act.act
        runID = context.act.runID
        nightID = context.act.night.id
    }

    func append(_ event: JournalEvent) throws {
        try journal.append(event, act: act, runID: runID, nightID: nightID)
    }
}

// Reconciling the board's copy of a Card's Managed Block into the Journal, before readiness is judged
// (P8.2): an edit to the prose is simply recorded, and Definition of Done clause edits are reconciled by
// identity. A Transcription Block's REFERENCE is read back (the visible `Contract:` line is the reference;
// spec: feature-authoring/author-an-architectural-brief#edited-reference) and matched against the Journal's
// records by what it says, never by position; the transcribed lines and their hash live in the Journal and
// are never read from the Card.
extension ReadinessCheck {
    /// Folds the board's copy into the Journal. Returns whether the Card's Managed Block now needs a rewrite
    /// (a clause was minted, or its Transcription Blocks changed): the caller makes the one rewrite per
    /// evaluation, after any unread reference has been read.
    func reconcile(parsed: ParsedCardBlock, card: CardRecord, context: BuildActContext) throws -> Bool {
        let stamp = ReconcileContext(context)
        let journal = stamp.journal

        if let scope = parsed.scope {
            let existingScope = try journal.declaredScope(cardID: card.id)
            if existingScope != scope {
                try journal.recordDeclaredScope(cardID: card.id, paths: scope)
            }
        }

        if let prose = parsed.briefProse {
            let existing = try journal.architecturalBriefProse(cardID: card.id)
            if existing.map({ !MarkdownEquivalence.rendersSame($0, prose) }) ?? true {
                try journal.recordArchitecturalBrief(cardID: card.id, prose: prose)
            }
        }

        let mintedAny = try reconcileClauses(parsed: parsed, card: card, stamp: stamp)
        let blocksChanged = try reconcileTranscriptions(parsed: parsed, card: card, context: context)
        return mintedAny || blocksChanged
    }

    /// Matches the board's Transcription Blocks to the Journal's records and writes the result, only when
    /// something changed. Returns whether it did.
    private func reconcileTranscriptions(
        parsed: ParsedCardBlock, card: CardRecord, context: BuildActContext
    ) throws -> Bool {
        let journal = context.act.journal
        let records = try journal.transcriptionBlocks(cardID: card.id)
        let matching = TranscriptionReferenceMatch.match(board: parsed.transcriptions, records: records)

        let keptRecords = matching.blocks.compactMap { match -> TranscriptionBlockRecord? in
            if case .kept(let record, _) = match { return record }
            return nil
        }
        let changed = !matching.deletions.isEmpty
            || keptRecords.count != matching.blocks.count
            || matching.blocks.contains { match in
                if case .kept(let record, let symbol) = match { return record.symbol != symbol }
                return false
            }
            || keptRecords.map(\.id) != keptRecords.map(\.id).sorted()
        guard changed else { return false }

        let nightID = context.act.night.id
        let rows = matching.blocks.map { match -> NewTranscriptionBlock in
            switch match {
            case .kept(let record, let symbol):
                return NewTranscriptionBlock(
                    repository: record.repository, paths: record.paths, ranges: record.ranges, symbol: symbol,
                    mainlineCommit: record.mainlineCommit, content: record.content, contentHash: record.contentHash,
                    authorSupplied: record.authorSupplied, authorSuppliedNightID: record.authorSuppliedNightID,
                    referenceText: record.referenceText
                )
            case .edited(let edit):
                // An unreadable line leaves nothing to record but the line itself; the read step reports why.
                return NewTranscriptionBlock(
                    repository: edit.repository, paths: edit.paths, ranges: edit.ranges, symbol: edit.symbol,
                    mainlineCommit: edit.commit, content: nil, contentHash: nil, authorSupplied: true,
                    authorSuppliedNightID: nightID, referenceText: edit.line
                )
            }
        }
        try journal.replaceTranscriptionBlocks(cardID: card.id, rows)
        return true
    }

    /// Returns whether any untagged clause was minted this pass.
    private func reconcileClauses(parsed: ParsedCardBlock, card: CardRecord, stamp: ReconcileContext) throws -> Bool {
        let journal = stamp.journal
        let existingClauses = try journal.clauses(issueID: card.issueID)
        let existingByCID = Dictionary(uniqueKeysWithValues: existingClauses.map { ($0.cid, $0) })
        var seenCIDs: Set<String> = []
        var mintedAny = false

        for parsedClause in parsed.clauses {
            guard let cid = parsedClause.cid else {
                try mintClause(parsedClause, card: card, stamp: stamp)
                mintedAny = true
                continue
            }
            seenCIDs.insert(cid)
            guard let existing = existingByCID[cid] else { continue }
            try reconcileTaggedClause(cid: cid, existing: existing, parsed: parsedClause, card: card, stamp: stamp)
        }

        for existing in existingClauses where !existing.deleted && !seenCIDs.contains(existing.cid) {
            try journal.markClauseDeleted(issueID: card.issueID, cid: existing.cid)
            try stamp.append(.clauseDeleted(issueID: card.issueID, cid: existing.cid))
        }

        return mintedAny
    }

    private func mintClause(_ parsedClause: ParsedClause, card: CardRecord, stamp: ReconcileContext) throws {
        let journal = stamp.journal
        let newCID = try journal.nextClauseID(issueID: card.issueID)
        try journal.insertClause(JournalStore.NewClause(
            cid: newCID, issueID: card.issueID, level: "card", text: parsedClause.text,
            locationID: parsedClause.citation ?? "", provenance: "Author-supplied",
            citationProvenance: "Author-supplied"
        ))
        try stamp.append(.clauseMinted(issueID: card.issueID, cid: newCID))
    }

    private func reconcileTaggedClause(
        cid: String, existing: ClauseRecord, parsed: ParsedClause, card: CardRecord, stamp: ReconcileContext
    ) throws {
        let journal = stamp.journal
        if !MarkdownEquivalence.rendersSame(existing.text, parsed.text) {
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "text_edited")
            try stamp.append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "text_edited"))
        }

        let newCitation = parsed.citation ?? ""
        if !MarkdownEquivalence.rendersSame(existing.locationID, newCitation) {
            try journal.updateClauseCitation(issueID: card.issueID, cid: cid, locationID: newCitation)
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "citation_edited")
            try stamp.append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "citation_edited"))
        }
    }
}
