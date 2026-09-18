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
// (P8.2): an Operator's edit inside a Transcription Block voids its stamp, an edit to the prose is
// simply recorded, and Definition of Done clause edits are reconciled by identity.
extension ReadinessCheck {
    func reconcile(parsed: ParsedCardBlock, card: CardRecord, context: BuildActContext) async throws {
        let stamp = ReconcileContext(context)
        let journal = stamp.journal

        try reconcileTranscriptions(parsed: parsed, card: card, stamp: stamp)

        if let scope = parsed.scope {
            let existingScope = try journal.declaredScope(cardID: card.id)
            if existingScope != scope {
                try journal.recordDeclaredScope(cardID: card.id, paths: scope)
            }
        }

        if let prose = parsed.briefProse {
            let existing = try journal.architecturalBriefProse(cardID: card.id)
            if existing != prose {
                try journal.recordArchitecturalBrief(cardID: card.id, prose: prose)
            }
        }

        let mintedAny = try reconcileClauses(parsed: parsed, card: card, stamp: stamp)

        if mintedAny, let outbox = context.act.outbox {
            let brief = ArchitecturalBrief(
                prose: try journal.architecturalBriefProse(cardID: card.id) ?? "",
                transcriptions: try journal.transcriptionBlocks(cardID: card.id).map(\.block)
            )
            let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox)
            _ = try await maintenance.maintain(card: card, brief: brief)
        }
    }

    private func reconcileTranscriptions(parsed: ParsedCardBlock, card: CardRecord, stamp: ReconcileContext) throws {
        let journal = stamp.journal
        let existingBlocks = try journal.transcriptionBlocks(cardID: card.id)
        for (index, parsedBlock) in parsed.transcriptions.enumerated() where index < existingBlocks.count {
            let row = existingBlocks[index]
            if !row.authorSupplied, parsedBlock.contentHash != row.contentHash {
                try journal.voidTranscriptionStamp(id: row.id, nightID: stamp.nightID)
                try stamp.append(
                    .transcriptionStampVoided(cardID: card.id, issueID: card.issueID, repository: row.repository)
                )
            }
            try journal.updateTranscriptionContent(
                id: row.id, content: parsedBlock.content, contentHash: parsedBlock.contentHash
            )
        }
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
        if existing.text != parsed.text {
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "text_edited")
            try stamp.append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "text_edited"))
        }

        let newCitation = parsed.citation ?? ""
        if existing.locationID != newCitation {
            try journal.updateClauseCitation(issueID: card.issueID, cid: cid, locationID: newCitation)
            try journal.invalidateClause(issueID: card.issueID, cid: cid, cause: "citation_edited")
            try stamp.append(.clauseInvalidated(issueID: card.issueID, cid: cid, cause: "citation_edited"))
        }
    }
}
