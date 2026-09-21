import Domain
import Foundation
import Journal

// The reclaim sequence itself (loop-state/reclaim-an-expired-lease, P8.10), split out of
// ExpiredLeaseSweep.swift to keep it under the file length limit.

extension ExpiredLeaseSweep {
    /// One Card's reclaim, after its Lease is already claimed under this run: the Pre-Reclaim Quiescence
    /// Gate, defensive classification of the dead run's open Attempt, the repost with its crash comment,
    /// and the `.cardReclaimed` event. Never throws for a not-quiescent Worktree — it appends
    /// `.cardReclaimDeferred` instead and returns, leaving the Attempt open and the Card as is, for the
    /// next Act to try again. The two events are distinct so the Night Summary never confuses a
    /// deferral with a real reclaim that happened to find no open Attempt.
    func reclaim(
        card: CardRecord, featureID: Int64, previousRunID: RunID, expiredAt: Date, now: Date
    ) async throws {
        if let remaining = try await notQuiescentHolderCount(card: card, featureID: featureID) {
            try journal.append(
                .cardReclaimDeferred(
                    cardID: card.id, issueID: card.issueID, previousRunID: previousRunID, remaining: remaining
                ),
                act: act, runID: runID, nightID: nightID, now: now
            )
            return
        }

        let outcome = try endOpenAttemptIfAny(card: card, featureID: featureID, previousRunID: previousRunID, now: now)
        try await repost(card: card, previousRunID: previousRunID, expiredAt: expiredAt, outcome: outcome, now: now)

        try journal.append(
            .cardReclaimed(
                cardID: card.id, issueID: card.issueID, previousRunID: previousRunID, attemptID: outcome.attemptID,
                outcome: outcome.consumedHow, routeExcluded: outcome.routeExcluded
            ),
            act: act, runID: runID, nightID: nightID, now: now
        )
    }

    /// The Pre-Reclaim Quiescence Gate: nil when this Feature holds no Worktree for the Card's
    /// repository, the path is gone, or fencing found it quiescent; the count of holders still there
    /// after the fencing timeout otherwise.
    private func notQuiescentHolderCount(card: CardRecord, featureID: Int64) async throws -> Int? {
        guard let worktree = try heldWorktree(featureID: featureID, repository: card.repository) else { return nil }
        switch await fencer.fence(worktreePath: WorktreeReconciler.expandedPath(worktree.path)) {
        case .notQuiescent(_, let remaining):
            return remaining.count
        case .quiescent, .pathMissing:
            return nil
        }
    }

    /// The Card's held Worktree, when this Feature holds one for its repository.
    private func heldWorktree(featureID: Int64, repository: String) throws -> WorktreeRecord? {
        try journal.worktrees(featureID: featureID).first { $0.repository == repository && $0.isHeld }
    }

    /// What the dead run's open Attempt (if any) ended as, and what to tell the board.
    private struct ReclaimEnding {
        var attemptID: Int64?
        var consumedHow: String?
        var routeExcluded = false
        var isSuccess = false
    }

    /// Ends the dead run's open Attempt, if it has one, from its defensive classification; recording the
    /// reviewer's known-good commit on a classified success. No open Attempt is not an error: the run may
    /// have died before recording one, or between Attempts.
    private func endOpenAttemptIfAny(
        card: CardRecord, featureID: Int64, previousRunID: RunID, now: Date
    ) throws -> ReclaimEnding {
        var result = ReclaimEnding()
        guard let open = try journal.attemptHistory(cardID: card.id).openAttempt else { return result }
        result.attemptID = open.id

        let classification = try classify(card: card, attempt: open, previousRunID: previousRunID)
        try journal.endAttempt(
            attemptID: open.id, ending: classification.ending, runID: runID, act: act, nightID: nightID, now: now
        )
        result.consumedHow = classification.ending.consumedHow
        result.routeExcluded = classification.ending.excludesRoute
        result.isSuccess = classification.ending == .success

        if result.isSuccess, let commit = classification.knownGoodCommit,
            let worktree = try heldWorktree(featureID: featureID, repository: card.repository) {
            try journal.recordWorktreeKnownGood(id: worktree.id, commit: commit, runID: runID, now: now)
        }
        return result
    }

    /// Reposts an In Progress Card back to Ready (or Done, on a classified success) with the crash
    /// comment. A Card that is not In Progress — already Done, Blocked, Waiting on You, Todo or
    /// Cancelled — is left exactly as it is; only the reclaim is recorded.
    private func repost(
        card: CardRecord, previousRunID: RunID, expiredAt: Date, outcome: ReclaimEnding, now: Date
    ) async throws {
        let currentCard = try journal.card(id: card.id)
        guard currentCard.state == .inProgress else { return }

        let transition: CardTransition = outcome.isSuccess ? .done : .ready
        if let projection {
            _ = try await projection.transition(card: currentCard, to: transition)
        } else {
            try journal.transitionCard(
                cardID: card.id, to: transition.state, runID: runID, act: act, nightID: nightID, now: now
            )
        }
        guard let outbox = projection?.outbox else { return }
        try await postCrashComment(
            outbox: outbox, card: currentCard,
            context: CrashCommentContext(
                previousRunID: previousRunID, expiredAt: expiredAt, attemptID: outcome.attemptID,
                consumedHow: outcome.consumedHow, destination: outcome.isSuccess ? "Done" : "Ready"
            )
        )
    }

    /// What the crash comment names, beyond the Card and the Outbox it posts through.
    private struct CrashCommentContext {
        let previousRunID: RunID
        let expiredAt: Date
        let attemptID: Int64?
        let consumedHow: String?
        let destination: String
    }

    /// Posts the crash comment through the Outbox, `cardID` deliberately nil: the Card Lease is released
    /// right after the reclaim, and a deferred delivery at write-back must not be refused for a Lease
    /// this run no longer holds — the Act Lease still fences it. Keyed for idempotency across a replay.
    private func postCrashComment(outbox: Outbox, card: CardRecord, context: CrashCommentContext) async throws {
        var body = """
            Yellowhammer reclaimed this Card: the Card is reclaimable, and no partial state was written \
            as if it were complete. Run \(context.previousRunID.rawValue) held this Card's Lease, which \
            expired at \(context.expiredAt.formatted(.iso8601)), and never released it.
            """
        if let attemptID = context.attemptID, let consumedHow = context.consumedHow {
            body += " Attempt \(attemptID): \(consumedHow)."
        }
        body += " The Card returned to \(context.destination)."
        let key = "lease-reclaim:\(card.issueID):\(context.previousRunID.rawValue)"
        let write = OutboxWrite(
            key: key, write: .createComment(issue: BoardObjectID(rawValue: card.issueID), body: body), cardID: nil
        )
        _ = try await outbox.post(write)
    }

    /// What the dead run's Attempt classifies to, and the reviewer's known-good commit on a success.
    private struct Classification {
        let ending: AttemptEnding
        let knownGoodCommit: String?
    }

    /// Defensive classification of `attempt` (loop-state/reclaim-an-expired-lease, P8.10): a valid,
    /// schema-conforming result file of the dead run's last pass that ends the Attempt, else the event
    /// log's last recorded pass step for it, else Crashed-Unknown.
    private func classify(
        card: CardRecord, attempt: AttemptRecord, previousRunID: RunID
    ) throws -> Classification {
        if let ending = try classifyFromResultFile(card: card, attempt: attempt, previousRunID: previousRunID) {
            return ending
        }
        if let status = try lastFailedExitStatus(card: card, previousRunID: previousRunID) {
            return Classification(ending: .hardFailure(.exitStatus(status)), knownGoodCommit: nil)
        }
        let reason = try crashedUnknownReason(card: card, previousRunID: previousRunID)
        return Classification(ending: .crashedUnknown(.reclaimed(reason)), knownGoodCommit: nil)
    }

    private func classifyFromResultFile(
        card: CardRecord, attempt: AttemptRecord, previousRunID: RunID
    ) throws -> Classification? {
        guard let resultReader,
            let passResult = try resultReader.lastPass(
                runID: previousRunID, issueID: card.issueID, attemptID: attempt.id
            ),
            let data = passResult.data, !data.isEmpty,
            let decoded = try? ResultFile.decode(data, expecting: passResult.pass)
        else { return nil }

        switch decoded {
        case .architect(let result):
            if case .failed(let reason) = result.outcome {
                return Classification(ending: .hardFailure(.reported(reason: reason)), knownGoodCommit: nil)
            }
            return nil
        case .worker(let result):
            return Self.classify(worker: result)
        case .reviewer(let result):
            switch result.outcome {
            case .approved(let judgedCommit, _):
                return Classification(ending: .success, knownGoodCommit: judgedCommit)
            case .changesRequested:
                return nil
            }
        case .selection, .breakdown, .verifier:
            // A Card's Attempt never runs an author Act or land Act pass.
            return nil
        }
    }

    private static func classify(worker result: WorkerResult) -> Classification? {
        switch result.outcome {
        case .failed(let reason):
            Classification(ending: .hardFailure(.reported(reason: reason)), knownGoodCommit: nil)
        case .question:
            Classification(ending: .question, knownGoodCommit: nil)
        case .completed:
            nil
        }
    }

    /// The dead run's last recorded pass step for this Card, in append order.
    private func lastPassStep(card: CardRecord, previousRunID: RunID) throws -> (step: CardRunStep, detail: String?)? {
        var last: (step: CardRunStep, detail: String?)?
        for record in try journal.events(ofType: .cardRunStep) where record.runID == previousRunID {
            guard case .cardRunStep(let cardID, _, let step, let detail) = record.event, cardID == card.id else {
                continue
            }
            guard step == .architect || step == .worker || step == .reviewer else { continue }
            last = (step, detail)
        }
        return last
    }

    private func lastFailedExitStatus(card: CardRecord, previousRunID: RunID) throws -> Int32? {
        guard let last = try lastPassStep(card: card, previousRunID: previousRunID), let detail = last.detail else {
            return nil
        }
        return CardRun.parseFailedExitStatus(detail)
    }

    /// A short, Operator-facing account of what was missing, from the dead run's last recorded pass step
    /// (or its absence): naming the pass currently unaccounted for is more useful than a bare "unknown".
    private func crashedUnknownReason(card: CardRecord, previousRunID: RunID) throws -> String {
        guard let last = try lastPassStep(card: card, previousRunID: previousRunID) else {
            return "no result file for the architect pass: the Attempt was recorded but no pass ran before the crash"
        }
        switch last.step {
        case .architect:
            return "no result file for the worker pass"
        case .worker:
            return "worker result arrived but the Attempt was cut off between passes"
        case .reviewer:
            return "reviewer result arrived but the Attempt was cut off between passes"
        default:
            return "no result file for the Card's Attempt"
        }
    }
}
