import Domain
import Foundation
import Journal

/// Projects a Card's (and the Feature Issue's) board-writing state through the Outbox, for one Project
/// (roadmap P5.8: board state writes for Cards and Features).
///
/// A transition is first written to the Journal — the Journal record is what backs Waiting on You and
/// Blocked, and Shelved is refused there too, not only here — and only then posted through the
/// Outbox, keyed on the Journal's own `state_version` so a crashed and resumed run replays the same
/// write rather than sending a stale one. The Journal transition stands even when the board write is
/// deferred: ``repost(_:reclaimingExpiredLeases:)`` replays it on a later Act, from `state_version` and
/// `board_state_version` alone, because the Outbox's own idempotency does not know which Card state a
/// killed run's entry was for. ``BuildAct`` calls it directly, entitled to reclaim an expired Card
/// Lease since it runs after ``ExpiredLeaseSweep``; ``DeferredCardStateReplay`` calls it for the author
/// and land Acts, which run no Card and so must not (issue #96).
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
    /// Shelved target or an already-shelved Card propagates the Journal's own refusal.
    ///
    /// A removed Card (trashed, or archived while in play; OQ142) is set aside: nothing is written to the
    /// Journal or posted, and the Card comes back `.unchanged` so a restore finds it as it stood. The
    /// check reads the Journal's own record, since the `card` the caller holds may predate the removal.
    public func transition(card: CardRecord, to transition: CardTransition) async throws -> Outcome {
        let current = try journal.card(id: card.id)
        guard !current.isRemovedFromBoard else {
            return .unchanged(current)
        }
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
    /// (``JournalStore/cardsWithUnpostedState()``, or the explicit `cards` a caller already resolved) —
    /// the board state written on a Night a run crashed mid-Act, or deferred (`cardLeaseNotHeld`) by a
    /// caller that wrote its transition and released the Lease before the board delivered it, and that
    /// no later Act will run again (Blocked, Waiting on You, Done, or any Card of a landed Cycle). The
    /// caller runs no Card here either: the Lease is claimed for the one write, then released, the same
    /// claim → write → release pattern ``ExpiredLeaseSweep`` and ``CardAutoBlock`` use. A Card whose
    /// Lease is held live by another run is skipped — that run is dispatching or transitioning it right
    /// now — and stays pending for a later repost. `reclaimingExpiredLeases` is forwarded to
    /// ``JournalStore/claimCardLease(cardID:runID:reclaimingExpired:policy:now:)``: `true` (the build
    /// Act's use, after ``ExpiredLeaseSweep`` has already run) takes over a dead run's expired lease;
    /// `false` (``DeferredCardStateReplay``, which runs no Card and precedes no sweep) leaves it held, so
    /// a later sweep still finds the evidence of the crashed Attempt. Stops after the first Card whose
    /// outcome is a budget deferral (rate-limited, transient, or behind such an entry) and releases that
    /// Card's Lease before returning: acting on a budget that is gone does less than waiting, and every
    /// further Card here would just re-hit the same refused budget — the rest stay pending for a later
    /// Act, mirroring ``Outbox/deliverPendingExclusively()``. Never touches the assignee: the operator's
    /// board identity is not stored in the Journal, so the assignment a Waiting on You transition wrote
    /// originally is left exactly as the board holds it, because nothing here clears it. Never reposts a
    /// Shelved Card — `cardsWithUnpostedState` excludes it — nor a removed one (OQ142), which an explicit
    /// `cards` list is filtered of too.
    public func repost(_ cards: [CardRecord]? = nil, reclaimingExpiredLeases: Bool = true) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for record in try cards ?? journal.cardsWithUnpostedState() where !record.isRemovedFromBoard {
            switch try journal.claimCardLease(
                cardID: record.id, runID: outbox.runID, reclaimingExpired: reclaimingExpiredLeases,
                now: outbox.clock()
            ) {
            case .held:
                continue
            case .claimed, .reclaimed:
                break
            }
            let blockReason = record.blockReason.flatMap { BlockReason(rawValue: $0) }
            let outcome: Outcome
            do {
                outcome = try await post(record: record, state: record.state, blockReason: blockReason, assignee: nil)
            } catch {
                _ = try? journal.releaseCardLease(cardID: record.id, runID: outbox.runID)
                throw error
            }
            outcomes.append(outcome)
            if case .deferred(_, let delivery) = outcome, Self.isBudgetDeferral(delivery) {
                try journal.releaseCardLease(cardID: record.id, runID: outbox.runID)
                return outcomes
            }
            try journal.releaseCardLease(cardID: record.id, runID: outbox.runID)
        }
        return outcomes
    }

    /// Whether a deferral is one that means the budget itself is gone for now (rate-limited, transient,
    /// or behind such an entry), as opposed to `cardLeaseNotHeld` — another run dispatching the Card
    /// right now, which is not a budget problem and never stops the loop.
    private static func isBudgetDeferral(_ delivery: OutboxDelivery) -> Bool {
        switch delivery.outcome {
        case .deferred(.rateLimited), .deferred(.transient), .deferred(.behindAnotherEntry):
            true
        default:
            false
        }
    }

    /// Projects the Feature Issue's board-writing state: it shares the team's workflow states, so no
    /// Journal Card row backs it — the Outbox entry, keyed on the target state, is the record. `.shelved`
    /// is refused (``BoardStateScopeError/shelvedIsNeverWritten``); Waiting on You requires the
    /// Operator's board identity and Blocked requires a Block Reason.
    @discardableResult
    public func transition(
        featureIssue: BoardObjectID,
        to state: CardState,
        blockReason: BlockReason? = nil,
        `operator`: BoardObjectID? = nil
    ) async throws -> OutboxDelivery {
        guard state != .shelved else {
            throw BoardStateScopeError.shelvedIsNeverWritten
        }
        if state == .blocked, blockReason == nil {
            throw BoardStateProjectionError.blockReasonRequired
        }

        var change = scope.labels.change(cardType: .featureCard, state: state, blockReason: blockReason)
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
        var change = scope.labels.change(cardType: .workCard, state: state, blockReason: blockReason)
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
    /// Blocked requires a Block Reason.
    case blockReasonRequired

    public var description: String {
        switch self {
        case .blockReasonRequired:
            "Blocked requires a Block Reason"
        }
    }
}
