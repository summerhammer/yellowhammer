import Domain
import Foundation
import Journal

// Reconciling the board's copy of a Card's Managed Block into the Journal, before readiness is judged
// (P8.2): an edit to the prose is simply recorded, and Definition of Done clause edits are reconciled by
// identity. A Transcription Block's REFERENCE is read back (the visible `Contract:` line is the reference;
// spec: feature-authoring/author-an-architectural-brief#edited-reference) and matched against the Journal's
// records by what it says, never by position; the transcribed lines and their hash live in the Journal and
// are never read from the Card.
//
// Import is the Board's side of field ownership (spec: board-projection / overview#field-ownership-and-sync):
// the Readiness Check imports before it judges, a Delta Read imports a Card whose block was edited, and a
// Managed Block rewrite imports from the description it just read before it renders. A field the human left
// unreadable (``InvalidBlockInput``) is not imported at all, so no Journal value is overwritten by half of it.
// The Card override (P22.7) is such a field: its lines are imported exactly as written, malformed or
// duplicated included, so no rewrite replaces them with a cached value. Judging them is the Readiness Check's.

/// Imports a Card's supported human input from a parsed Managed Block into the Journal, under the identity
/// (`act`, `runID`, `nightID`) its events are appended with.
struct CardInputReconciler {
    let journal: JournalStore
    let act: Act?
    let runID: RunID
    let nightID: Int64?

    /// What an import changed in the Journal.
    struct Imported: Equatable {
        /// The input fields whose Journal value changed, in a fixed order.
        var fields: [String] = []
        /// Whether the Card's Managed Block now needs a rewrite (a clause was minted, or its Transcription
        /// Blocks changed): the Readiness Check makes the one rewrite per evaluation.
        var needsRewrite = false
        /// The input fields the human left unreadable (``InvalidBlockInput``), including a Definition of Done
        /// section that is gone while the Journal still holds its clauses. Those fields were not imported.
        var invalid: [InvalidBlockInput] = []

        var changedAnything: Bool { !fields.isEmpty }
    }

    init(journal: JournalStore, act: Act?, runID: RunID, nightID: Int64?) {
        self.journal = journal
        self.act = act
        self.runID = runID
        self.nightID = nightID
    }

    init(_ context: BuildActContext) {
        self.init(
            journal: context.act.journal, act: context.act.act, runID: context.act.runID,
            nightID: context.act.night.id
        )
    }

    func append(_ event: JournalEvent) throws {
        try journal.append(event, act: act, runID: runID, nightID: nightID)
    }

    /// Folds the board's copy into the Journal. A `partial` import (a Delta Read's) takes scope, the brief and
    /// edits to tagged clauses, and leaves what needs the block rewritten afterwards — minting a clause for an
    /// untagged line, and reading a Transcription Block reference — to the Readiness Check or the rewrite that
    /// writes the result back: only that rewrite stops the same line being read as new again.
    func reconcile(parsed: ParsedCardBlock, card: CardRecord, partial: Bool = false) throws -> Imported {
        var imported = Imported()
        imported.invalid = parsed.invalid
        var dodInvalid = parsed.isInvalid("definition of done")
        if !parsed.hasDefinitionOfDoneSection, try !journal.clauses(issueID: card.issueID).isEmpty {
            imported.invalid.append(InvalidBlockInput(
                field: "definition of done",
                reason: "the `### Definition of Done` section is missing from the Managed Block"
            ))
            dodInvalid = true
        }

        if let scope = parsed.scope, !parsed.isInvalid("scope") {
            let existingScope = try journal.declaredScope(cardID: card.id)
            if existingScope != scope {
                try journal.recordDeclaredScope(cardID: card.id, paths: scope)
                imported.fields.append("scope")
            }
        }

        // Linear re-escapes Markdown punctuation in a stored description, so an escape-only difference from
        // the held lines is Linear's rewrite, not an Operator edit; the held (earlier) spelling stays.
        if try !CardOverrideField.sameIgnoringEscapes(
            journal.cardOverrideLines(cardID: card.id), parsed.cardOverrideLines
        ), try journal.recordCardOverrideLines(cardID: card.id, lines: parsed.cardOverrideLines) {
            imported.fields.append("card override")
            // An explicit set or clear resolves an open legacy `Override` conversion for good (P22.9).
            try journal.noteCardOverrideEdited(issueID: card.issueID, lines: parsed.cardOverrideLines)
        }

        if let prose = parsed.briefProse {
            let existing = try journal.architecturalBriefProse(cardID: card.id)
            if existing.map({ !MarkdownEquivalence.rendersSame($0, prose) }) ?? true {
                try journal.recordArchitecturalBrief(cardID: card.id, prose: prose)
                imported.fields.append("brief")
            }
        }

        if !dodInvalid {
            let clauses = try reconcileClauses(parsed: parsed, card: card, mintsUntagged: !partial)
            if clauses.changed { imported.fields.append("definition of done") }
            imported.needsRewrite = clauses.minted
        }
        if !partial, try reconcileTranscriptions(parsed: parsed, card: card) {
            imported.fields.append("references")
            imported.needsRewrite = true
        }
        return imported
    }

    /// Matches the board's Transcription Blocks to the Journal's records and writes the result, only when
    /// something changed. Returns whether it did.
    private func reconcileTranscriptions(parsed: ParsedCardBlock, card: CardRecord) throws -> Bool {
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

    /// Whether any untagged clause was minted this pass, and whether any clause changed at all.
    private func reconcileClauses(
        parsed: ParsedCardBlock, card: CardRecord, mintsUntagged: Bool
    ) throws -> (minted: Bool, changed: Bool) {
        let existingClauses = try journal.clauses(issueID: card.issueID)
        let existingByCID = Dictionary(uniqueKeysWithValues: existingClauses.map { ($0.cid, $0) })
        var seenCIDs: Set<String> = []
        var mintedAny = false
        var changed = false
        let taggedOnBoard = Set(parsed.clauses.compactMap(\.cid))

        for parsedClause in parsed.clauses {
            guard let cid = parsedClause.cid else {
                // A line already minted by an earlier import whose tag was never written back is that clause.
                let alreadyMinted = existingClauses.first {
                    !$0.deleted && !taggedOnBoard.contains($0.cid) && !seenCIDs.contains($0.cid)
                        && MarkdownEquivalence.rendersSame($0.text, parsedClause.text)
                        && MarkdownEquivalence.rendersSame($0.locationID, parsedClause.citation ?? "")
                }
                if let alreadyMinted {
                    // Present on the board, still untagged: the clause stays, it is not deleted below.
                    seenCIDs.insert(alreadyMinted.cid)
                    continue
                }
                guard mintsUntagged else { continue }
                try mintClause(parsedClause, card: card)
                mintedAny = true
                changed = true
                continue
            }
            seenCIDs.insert(cid)
            guard let existing = existingByCID[cid] else { continue }
            if try reconcileTaggedClause(cid: cid, existing: existing, parsed: parsedClause, card: card) {
                changed = true
            }
        }

        for existing in existingClauses where !existing.deleted && !seenCIDs.contains(existing.cid) {
            try journal.markClauseDeleted(issueID: card.issueID, cid: existing.cid)
            try append(.clauseDeleted(issueID: card.issueID, cid: existing.cid))
            changed = true
        }

        return (mintedAny, changed)
    }

    private func mintClause(_ parsedClause: ParsedClause, card: CardRecord) throws {
        let newCID = try journal.nextClauseID(issueID: card.issueID)
        try journal.insertClause(JournalStore.NewClause(
            cid: newCID, issueID: card.issueID, level: "card", text: parsedClause.text,
            locationID: parsedClause.citation ?? "", provenance: "Author-supplied",
            citationProvenance: "Author-supplied"
        ))
        try append(.clauseMinted(issueID: card.issueID, cid: newCID))
    }

    /// Whether the clause changed.
    private func reconcileTaggedClause(
        cid: String, existing: ClauseRecord, parsed: ParsedClause, card: CardRecord
    ) throws -> Bool {
        var changed = false
        if !MarkdownEquivalence.rendersSame(existing.text, parsed.text) {
            try journal.updateClauseText(issueID: card.issueID, cid: cid, text: parsed.text)
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "text_edited")
            try append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "text_edited"))
            changed = true
        }

        let newCitation = parsed.citation ?? ""
        if !MarkdownEquivalence.rendersSame(existing.locationID, newCitation) {
            try journal.updateClauseCitation(issueID: card.issueID, cid: cid, locationID: newCitation)
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "citation_edited")
            try append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "citation_edited"))
            changed = true
        }
        return changed
    }
}
