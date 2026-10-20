import Domain
import Foundation
import Journal

// Conditioned writes (roadmap P22.4; spec: board-projection / write-board-updates-through-the-outbox,
// "Revalidate the originating condition before delivery").
//
// A state- or label-affecting `updateIssue` is a decision taken from what Yellowhammer knew at that moment:
// the Card was Blocked in the Journal, and the board last held it In Progress. The Journal's copy of that
// decision can outlive the board it was made against — a deferred write, a crashed Act's replay, a clock
// expiry queued before the Operator answered. So the write records the board workflow state it was decided
// against, and immediately before delivery the issue is read again: a board that no longer holds that state
// (and is not already at the write's own target) means a human moved it, and the cached value is never
// applied. The entry is superseded, and the next Delta Read recomputes from what the board now holds.
//
// Residual race, not closed here: Linear's `issueUpdate` has no server-side compare-and-swap. A human who
// saves between this pre-flight read and the mutation is still overwritten, and the Lease only establishes
// that this run is the writer, not that the board is fresh. The Outbox narrows that window to one request
// and makes no claim of atomic protection against concurrent edits.

/// What Yellowhammer knew of an issue's workflow state when it decided a write.
struct KnownBoardState: Equatable {
    var stateID: String
    var revision: Date?
}

extension Outbox {
    /// The condition a write records when it is accepted, or nil when it carries none: a create, a comment,
    /// a description rewrite, a group member or a compensation never does.
    func condition(for write: OutboxWrite, groupID: String?) throws -> KnownBoardState? {
        guard write.revalidates, groupID == nil,
              case .updateIssue(let issue, let change, _) = write.write,
              change.workflowState != nil || !change.addLabels.isEmpty || !change.removeLabels.isEmpty
        else { return nil }
        if let expected = write.expectedState { return KnownBoardState(stateID: expected.rawValue, revision: nil) }
        return try knownBoardState(of: issue)
    }

    /// The workflow state the board is expected to hold for `issue` when the next write reaches it: the
    /// target of Yellowhammer's latest accepted state write (pending ones deliver first, in order), or the
    /// latest Delta Read observation when that is newer than the last write Yellowhammer applied. Nil when
    /// neither is known — such a write is delivered as it always was.
    func knownBoardState(of issue: BoardObjectID) throws -> KnownBoardState? {
        var known: (state: KnownBoardState, at: Date)?
        let decoder = JSONDecoder()
        for entry in try journal.outboxEntries(forIssue: issue.rawValue)
        where entry.state == .pending || entry.state == .applied {
            guard let write = try? decoder.decode(BoardWrite.self, from: Data(entry.payload.utf8)) else { continue }
            let target: BoardObjectID?
            switch write {
            case .updateIssue(_, let change, _): target = change.workflowState
            case .createIssue(let draft, _) where entry.result == issue.rawValue: target = draft.workflowState
            default: target = nil
            }
            guard let target else { continue }
            let at = entry.state == .pending ? Date.distantFuture : (entry.sentAt ?? entry.createdAt)
            known = (KnownBoardState(stateID: target.rawValue, revision: nil), at)
        }
        if let observed = try journal.observedIssue(issue.rawValue), observed.updatedAt > (known?.at ?? .distantPast) {
            known = (
                KnownBoardState(stateID: observed.workflowState.id.rawValue, revision: observed.updatedAt),
                observed.updatedAt
            )
        }
        return known?.state
    }

    /// Whether the board still holds the condition `entry` recorded. The board is at the expected state, or
    /// already at the write's own target (a replay after the board applied it): in both the write goes ahead.
    func conditionHolds(_ entry: OutboxEntry, write: BoardWrite, observed: BoardObject?) -> Bool {
        guard let expected = entry.expectedStateID, let observed else { return true }
        var accepted: Set<String> = [expected]
        if case .updateIssue(_, let change, _) = write, let target = change.workflowState {
            accepted.insert(target.rawValue)
        }
        return accepted.contains(observed.workflowState.id.rawValue)
    }

    /// Records that a human moved the issue: the entry is superseded, never sent, and an event names both
    /// states. The Delta Read that follows imports what the human did.
    func supersede(_ entry: OutboxEntry, observed: BoardObject?) throws -> OutboxDelivery {
        let observedName = observed.map { "\($0.workflowState.name) (\($0.workflowState.id.rawValue))" } ?? "unknown"
        let reason = "the board no longer holds the state this write was decided against "
            + "(expected \(entry.expectedStateID ?? "none"), the board holds \(observedName)); "
            + "the write was not delivered and the Delta Read recomputes from the board"
        let superseded = try journal.markOutboxSuperseded(id: entry.id, reason: reason)
        try append(.boardWriteSuperseded(
            clientID: entry.clientID, operation: entry.operation, issueID: entry.issueID,
            expectedState: entry.expectedStateID, observedState: observed?.workflowState.id.rawValue
        ))
        // Every later conditioned write to the issue was decided against the state this one would have written,
        // which the board did not take: they are stale for the same reason, and are set aside with it.
        for later in try journal.pendingOutboxEntries()
        where later.id > entry.id && later.issueID == entry.issueID && later.expectedStateID != nil {
            _ = try journal.markOutboxSuperseded(id: later.id, reason: reason)
            try append(.boardWriteSuperseded(
                clientID: later.clientID, operation: later.operation, issueID: later.issueID,
                expectedState: later.expectedStateID, observedState: observed?.workflowState.id.rawValue
            ))
        }
        // The Journal's state for the Card is recomputed from what the human did: it is not reposted over it.
        if let cardID = entry.cardID {
            try journal.recordCardBoardState(
                cardID: cardID, version: try journal.card(id: cardID).stateVersion, runID: runID, now: clock()
            )
        }
        return OutboxDelivery(entry: superseded, outcome: .superseded(reason: reason))
    }

    /// The issue a write addresses, read once before delivery: the archived check and the condition check
    /// share this read. Nil without a reading board, for an archive (itself the mutation) and for a create.
    func readTarget(_ write: BoardWrite) async throws -> BoardObject? {
        guard let reading else { return nil }
        if case .archiveIssue = write { return nil }
        guard let issue = write.issueID else { return nil }
        return try await reading.issue(issue)
    }
}
