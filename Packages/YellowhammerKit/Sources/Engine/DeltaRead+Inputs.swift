import Domain
import Foundation
import Journal

// What a Delta Read does with a known Card's description and with the writes still queued for it, split out of
// DeltaRead.swift to keep that file under the type-length limit.

extension DeltaRead {
    /// The Card's board copy against what the Journal last wrote: whether the Managed Block was edited, the
    /// prose outside it, the repository it names — and, when the block was edited, the supported input in it
    /// imported into the Journal. The Readiness Check still re-validates the Card at dispatch.
    func describeManagedBlock(
        card: CardRecord, object: BoardObject, stateDiffers: Bool, inputs: CardInputs
    ) throws -> CardChange {
        var change = CardChange(
            card: card, object: object, stateDiffers: stateDiffers, managedBlockEdited: nil, proseEdited: nil,
            delimitersBroken: nil, repositoryOnBoard: nil
        )
        var block: ManagedBlockFence.Parts?
        switch ManagedBlockFence.parts(of: object.description) {
        case .failure(let failure):
            change.delimitersBroken = failure
        case .success(let parts):
            if let posted = try journal.managedBlockLastPostedHash(issueID: card.issueID) {
                change.managedBlockEdited = parts.blockHash != posted
            }
            if let preserved = inputs.preservedProseHashes[card.issueID] {
                change.proseEdited = parts.preservedProseHash != preserved
            }
            change.repositoryOnBoard = Self.repository(inBlock: parts.block)
            block = parts
        }
        // Supported input the Operator edited inside the markers is imported by every Act that reads it, not
        // only by the build Act's Readiness Check: a Managed Block rendered later (by any Act) then starts from
        // the Journal's current inputs. The Readiness Check still re-validates the Card at dispatch.
        if let block, change.managedBlockEdited == true {
            try importInputs(from: block, card: card, replayed: inputs.replayed, into: &change)
        }
        return change
    }

    func importInputs(
        from parts: ManagedBlockFence.Parts, card: CardRecord, replayed: Bool, into change: inout CardChange
    ) throws {
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        let reconciler = CardInputReconciler(journal: journal, act: act, runID: runID, nightID: nightID)
        let imported = try reconciler.reconcile(parsed: parsed, card: card, partial: true)
        change.importedInputs = imported.fields
        change.invalidInputs = imported.invalid
        guard !replayed else { return }
        if imported.changedAnything {
            try append(.managedBlockInputImported(
                issueID: card.issueID, fields: imported.fields.joined(separator: ", ")
            ))
        }
        if !imported.invalid.isEmpty {
            let reason = imported.invalid.map { "\($0.field): \($0.reason)" }.joined(separator: "; ")
            try append(.managedBlockInputInvalid(issueID: card.issueID, reason: reason))
        }
    }

    /// Whether a write of Yellowhammer's own is still in flight to this Card's issue, after superseding the
    /// pending writes the board has already outrun. Only the oldest conditioned write is tested against the
    /// board: a later one is decided against the state its predecessor will write, so it waits behind it.
    func supersedingStalePendingWrites(
        of card: inout CardRecord, pending: [OutboxEntry], boardState: BoardWorkflowState
    ) throws -> Bool {
        guard !pending.isEmpty else { return false }
        let conditioned = pending.filter { $0.expectedStateID != nil }
        // A pending comment or description rewrite says nothing about the issue's state, so the Operator's move
        // is read as the Operator's. Every pending state write records the condition it was decided against.
        guard let first = conditioned.first else { return false }
        var accepted: Set<String> = [first.expectedStateID ?? ""]
        if case .updateIssue(_, let change, _)? = try? JSONDecoder().decode(
            BoardWrite.self, from: Data(first.payload.utf8)
        ), let target = change.workflowState {
            accepted.insert(target.rawValue)
        }
        if accepted.contains(boardState.id.rawValue) { return true }
        for entry in conditioned {
            _ = try journal.markOutboxSuperseded(
                id: entry.id,
                reason: "the board holds \(boardState.name) (\(boardState.id.rawValue)), not the state this write "
                    + "was decided against; the write was not delivered"
            )
            try append(.boardWriteSuperseded(
                clientID: entry.clientID, operation: entry.operation, issueID: entry.issueID,
                expectedState: entry.expectedStateID, observedState: boardState.id.rawValue
            ))
        }
        // The Journal's state for the Card is recomputed from what the human did, not reposted over it.
        try journal.recordCardBoardState(cardID: card.id, version: card.stateVersion, runID: runID, now: clock())
        return false
    }

    /// The hash of the prose each issue's last Managed Block write preserved, from the audit events.
    func lastPreservedProseHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for record in try journal.events(ofType: .managedBlockWritten) {
            if case .managedBlockWritten(let issueID, let preservedProseHash, _) = record.event {
                hashes[issueID] = preservedProseHash
            }
        }
        return hashes
    }
}
