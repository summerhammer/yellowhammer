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
        // The human's state is not reposted over: the Card's next reconcile imports it through the Work Card
        // board inputs (Operator Done, an Operator re-ready, Shelved), or reports it restated.
        try journal.recordCardBoardState(cardID: card.id, version: card.stateVersion, runID: runID, now: clock())
        return false
    }

    /// A Card the board does not show Shelved and the Journal does not hold Shelved: Done by the Operator, an
    /// Operator re-ready, or a re-stated board copy. Returns true when the board must be restated.
    func reconcileNonShelved(
        card: inout CardRecord,
        boardState: BoardWorkflowState,
        pending: [OutboxEntry],
        observation: BoardRevision,
        into report: inout DeltaReadReport
    ) throws -> Bool {
        let replayed = observation.replayed
        guard boardState.name != card.state.rawValue else { return false }
        // A Done Card read in another completed-type state (a team state named "Merged") is not a divergence.
        if card.state == .done, boardState.category == .completed { return false }
        // A write of ours still on its way to the board is not the Operator's doing; a board that holds
        // neither the state it was decided against nor its target means a human moved the issue, and the
        // write is superseded so the human's state is read as input rather than hidden behind it.
        if try supersedingStalePendingWrites(of: &card, pending: pending, boardState: boardState) { return false }
        // A completed-type state no write of ours is on its way to is the Operator's Done, from any state.
        // Every Act's read applies it: the settle in the same Act must see the Card Done.
        if try operatorDoneApplies(card: card, boardState: boardState, pending: pending) {
            card = try applyOperatorDone(card: card, pending: pending, into: &report)
            return false
        }
        if movedOutOfDoneApplies(card: card, boardState: boardState, pending: pending) {
            card = try applyMovedOutOfDone(card: card, into: &report)
            return false
        }
        // The board copy a non-build read moved out of Done, replayed by the build Act, is that same move: it is
        // not also the re-ready, which needs a later revision (the Operator moving the Blocked Card to Todo).
        if try movedOutOfDoneBy(observation, card: card) { return false }
        if try reReadyIfBlocked(card: &card, boardState: boardState, into: &report) {
            return false
        }
        // The board moved the Card to a state the Journal did not write and no Work Card board input
        // covers. The Journal is authoritative: the divergence is recorded, and the board copy is not adopted.
        report.restated.append(RestatedCard(card: card, boardState: boardState))
        if !replayed {
            try append(.cardRestated(
                cardID: card.id, issueID: card.issueID, journalState: card.state, boardState: boardState.name
            ))
        }
        return true
    }

    /// Whether a Done Card was moved out of Done (board-projection/moved-out-of-done, OQ199): the board holds a
    /// state that is neither completed nor cancelled, the board has confirmed the Journal's Done, and no state
    /// write of ours is still pending for the issue (a Done write still deferred means the board has not caught
    /// up, which is not the Operator's move).
    func movedOutOfDoneApplies(
        card: CardRecord, boardState: BoardWorkflowState, pending: [OutboxEntry]
    ) -> Bool {
        // A state type this build does not know (nil) is not read as out of Done: a Card is never Blocked over it.
        guard card.state == .done, let category = boardState.category, category != .completed, category != .shelved,
              (card.boardStateVersion ?? -1) >= card.stateVersion else { return false }
        return !pending.contains { Self.carriesStateChange($0) }
    }

    /// Whether `observation` is a replayed board copy no later than the Card's move out of Done: the revision
    /// the move was read from, not a re-ready the Operator made after it. The board's revision time is compared
    /// with the Journal's record of the move, allowing the clock difference the read's own overlap allows
    /// (``syncOverlap``); the Operator can only re-ready after seeing the Card Blocked, which Yellowhammer posts
    /// after the move, so a genuine re-ready is later by that whole round trip.
    func movedOutOfDoneBy(_ observation: BoardRevision, card: CardRecord) throws -> Bool {
        guard observation.replayed, card.state == .blocked,
              card.blockReason == BlockReason.movedOutOfDone.rawValue,
              let movedAt = try journal.movedOutOfDoneAt(cardID: card.id) else { return false }
        return observation.updatedAt <= movedAt.addingTimeInterval(Self.syncOverlap)
    }

    /// Records the Card Blocked `moved out of Done`, Journal-only: the repost projects Blocked to the board.
    func applyMovedOutOfDone(card: CardRecord, into report: inout DeltaReadReport) throws -> CardRecord {
        let blocked = try journal.transitionCard(
            cardID: card.id, to: .blocked, blockReason: .movedOutOfDone,
            runID: runID, act: act, nightID: nightID, now: clock()
        )
        report.movedOutOfDone.append(blocked)
        return blocked
    }

    private static func carriesStateChange(_ entry: OutboxEntry) -> Bool {
        guard case .updateIssue(_, let change, _)? = try? JSONDecoder().decode(
            BoardWrite.self, from: Data(entry.payload.utf8)
        ) else { return false }
        return change.workflowState != nil
    }

    /// Whether the board's completed-type state is the Operator's: the Journal holds the Card neither as Done
    /// nor already Done by the Operator, and no write of ours still pending for the issue targets the state the
    /// board holds (that state is Yellowhammer's, not the Operator's).
    func operatorDoneApplies(
        card: CardRecord, boardState: BoardWorkflowState, pending: [OutboxEntry]
    ) throws -> Bool {
        guard boardState.category == .completed, card.state != .done else { return false }
        for entry in pending {
            guard case .updateIssue(_, let change, _)? = try? JSONDecoder().decode(
                BoardWrite.self, from: Data(entry.payload.utf8)
            ) else { continue }
            if change.workflowState?.rawValue == boardState.id.rawValue { return false }
        }
        return true
    }

    /// Records the Operator's Done (spec: board-projection / operator-done) and aborts the Card's pending
    /// writes that carry a workflow-state change: the board already holds the Card's final state, and a write
    /// of ours must not move it. Pending comment and description writes are left to deliver.
    func applyOperatorDone(
        card: CardRecord, pending: [OutboxEntry], into report: inout DeltaReadReport
    ) throws -> CardRecord {
        // `pending` was read before this Card's reconcile began, so some may have been superseded since: the
        // Journal aborts only those still pending, in the same transaction as the Done.
        let stateWrites = pending.filter { entry in
            guard case .updateIssue(_, let change, _)? = try? JSONDecoder().decode(
                BoardWrite.self, from: Data(entry.payload.utf8)
            ) else { return false }
            return change.workflowState != nil
        }
        let done = try journal.markCardOperatorDone(
            cardID: card.id, runID: runID, act: act, nightID: nightID,
            abortingOutboxEntryIDs: stateWrites.map(\.id), now: clock()
        )
        report.operatorDone.append(done)
        return done
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

/// The board copy a Card is reconciled from: whether the build Act replays it from an earlier read, and the
/// board's revision time.
struct BoardRevision {
    var replayed: Bool
    var updatedAt: Date
}
