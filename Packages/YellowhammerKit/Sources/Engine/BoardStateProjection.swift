import Domain
import Foundation
import Journal

/// Projects a Card's (and the Feature Issue's) board-writing state through the Outbox, for one Project
/// (roadmap P5.8: board state writes for Cards and Features).
///
/// A transition is first written to the Journal — the Journal record is what backs Waiting on You and
/// Blocked, and Cancelled is refused there too, not only here — and only then posted through the
/// Outbox, keyed on the Journal's own `state_version` so a crashed and resumed run replays the same
/// write rather than sending a stale one. The Journal transition stands even when the board write is
/// deferred: ``repost()`` replays it on a later Act, from `state_version` and `board_state_version`
/// alone, because the Outbox's own idempotency does not know which Card state a killed run's entry was
/// for.
public struct BoardStateProjection: Sendable {
    public let journal: JournalStore
    public let outbox: Outbox
    public let scope: BoardStateScope

    public init(journal: JournalStore, outbox: Outbox, scope: BoardStateScope) {
        self.journal = journal
        self.outbox = outbox
        self.scope = scope
    }

    /// The Outbox key for a Card's state write at one `state_version`: replaying the same version posts
    /// the same write, and a later version is a new key entirely.
    public static func stateKey(issueID: String, version: Int) -> String {
        "state:\(issueID):\(version)"
    }

    /// The Outbox key for a Feature Issue's state write: keyed on the target state itself, since no
    /// Journal state row (and so no version) is kept for the Feature Issue by this phase.
    public static func featureStateKey(issueID: String, state: CardState) -> String {
        "feature-state:\(issueID):\(state.rawValue)"
    }

    public enum Outcome: Equatable, Sendable {
        /// The Journal reported a no-op transition (same state, same reasons): nothing was posted.
        case unchanged(CardRecord)
        case posted(CardRecord, OutboxDelivery)
        case deferred(CardRecord, OutboxDelivery)
        case failed(CardRecord, OutboxDelivery)
    }

    /// Writes `transition` to the Journal, then posts the board write it implies. Never throws for a
    /// deferral — the Journal transition stands regardless, and ``repost()`` replays it — but a
    /// Cancelled target or an already-cancelled Card propagates the Journal's own refusal.
    public func transition(card: CardRecord, to transition: CardTransition) async throws -> Outcome {
        var assignee: BoardObjectID?
        if case .waitingOnYou(_, let operatorID) = transition {
            assignee = operatorID
        }

        let record = try journal.transitionCard(
            cardID: card.id,
            to: transition.state,
            waitingReason: transition.waitingReason,
            blockReason: transition.blockReason,
            runID: outbox.runID,
            act: outbox.act,
            nightID: outbox.nightID
        )

        guard record.stateVersion != card.stateVersion else {
            return .unchanged(record)
        }

        return try await post(
            record: record, state: transition.state, blockReason: transition.blockReason, assignee: assignee
        )
    }

    /// Reposts every Card whose board projection has not caught up with its Journal state
    /// (``JournalStore/cardsWithUnpostedState()``) — the board state written on a Night a run crashed
    /// mid-Act, or deferred (`cardLeaseNotHeld`) by a caller that wrote its transition and released the
    /// Lease before the board delivered it, and that no later Act will run again (Blocked, Waiting on
    /// You, Done, or any Card of a landed Cycle). The caller runs no Card here either: the Lease is
    /// claimed for the one write, then released, the same claim → write → release pattern
    /// ``ExpiredLeaseSweep`` and ``CardAutoBlock`` use. A Card whose Lease is held live by another run
    /// is skipped — that run is dispatching or transitioning it right now — and stays pending for a
    /// later repost. Never touches the assignee: the operator's board identity is not stored in the
    /// Journal, so the assignment a Waiting on You transition wrote originally is left exactly as the
    /// board holds it, because nothing here clears it. Never reposts a Cancelled Card —
    /// `cardsWithUnpostedState` excludes it.
    public func repost() async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for record in try journal.cardsWithUnpostedState() {
            switch try journal.claimCardLease(cardID: record.id, runID: outbox.runID, now: outbox.clock()) {
            case .held:
                continue
            case .claimed, .reclaimed:
                break
            }
            let blockReason = record.blockReason.flatMap { BlockReason(rawValue: $0) }
            do {
                outcomes.append(
                    try await post(record: record, state: record.state, blockReason: blockReason, assignee: nil)
                )
            } catch {
                _ = try? journal.releaseCardLease(cardID: record.id, runID: outbox.runID)
                throw error
            }
            try journal.releaseCardLease(cardID: record.id, runID: outbox.runID)
        }
        return outcomes
    }

    /// Projects the Feature Issue's board-writing state: it shares the team's workflow states, so no
    /// Journal Card row backs it — the Outbox entry, keyed on the target state, is the record. `.cancelled`
    /// is refused (``BoardStateScopeError/cancelledIsNeverWritten``); Waiting on You requires the
    /// Operator's board identity and Blocked requires a Block Reason.
    @discardableResult
    public func transition(
        featureIssue: BoardObjectID,
        to state: CardState,
        blockReason: BlockReason? = nil,
        `operator`: BoardObjectID? = nil
    ) async throws -> OutboxDelivery {
        guard state != .cancelled else {
            throw BoardStateScopeError.cancelledIsNeverWritten
        }
        if state == .waitingOnYou, `operator` == nil {
            throw BoardStateProjectionError.operatorRequired
        }
        if state == .blocked, blockReason == nil {
            throw BoardStateProjectionError.blockReasonRequired
        }

        var change = scope.labels.change(objectType: "Feature", state: state, blockReason: blockReason)
        change.workflowState = try scope.id(for: state)
        if let `operator` {
            change.assignee = .set(`operator`)
        }

        let key = Self.featureStateKey(issueID: featureIssue.rawValue, state: state)
        let write = OutboxWrite(key: key, write: .updateIssue(issue: featureIssue, change: change, undo: nil))
        return try await outbox.post(write)
    }

    // MARK: - Private

    private func post(
        record: CardRecord, state: CardState, blockReason: BlockReason?, assignee: BoardObjectID?
    ) async throws -> Outcome {
        let issue = BoardObjectID(rawValue: record.issueID)
        var change = scope.labels.change(objectType: "Card", state: state, blockReason: blockReason)
        change.workflowState = try scope.id(for: state)
        if let assignee {
            change.assignee = .set(assignee)
        }

        let key = Self.stateKey(issueID: record.issueID, version: record.stateVersion)
        let write = OutboxWrite(
            key: key, write: .updateIssue(issue: issue, change: change, undo: nil), cardID: record.id
        )
        let delivery = try await outbox.post(write)
        return try await outcome(for: delivery, record: record, key: key)
    }

    private func outcome(for delivery: OutboxDelivery, record: CardRecord, key: String) async throws -> Outcome {
        switch delivery.outcome {
        case .applied, .alreadyApplied:
            try journal.recordCardBoardState(cardID: record.id, version: record.stateVersion, runID: outbox.runID)
            return .posted(record, delivery)
        case .deferred(.behindAnotherEntry):
            if let entry = try journal.outboxEntry(clientID: outbox.clientID(for: key)), entry.state == .applied {
                try journal.recordCardBoardState(cardID: record.id, version: record.stateVersion, runID: outbox.runID)
                return .posted(record, delivery)
            }
            return .deferred(record, delivery)
        case .deferred:
            return .deferred(record, delivery)
        case .aborted, .failed:
            return .failed(record, delivery)
        }
    }
}

public enum BoardStateProjectionError: Error, Equatable, CustomStringConvertible {
    /// Waiting on You requires the Operator's board identity, so Linear's assignment notifies them.
    case operatorRequired
    /// Blocked requires a Block Reason.
    case blockReasonRequired

    public var description: String {
        switch self {
        case .operatorRequired:
            "Waiting on You requires the Operator's board identity"
        case .blockReasonRequired:
            "Blocked requires a Block Reason"
        }
    }
}
