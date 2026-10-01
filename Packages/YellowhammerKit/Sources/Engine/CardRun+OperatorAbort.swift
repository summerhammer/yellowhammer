import Domain
import Foundation
import Journal

extension CardRun {
    /// Runs the passes beside a poller that checks the Journal for the Operator's abort request every
    /// ``operatorAbortPoll``. A pass that ends on its own before the request is noticed keeps its own
    /// ending. When the request is seen first, the passes are cancelled and awaited until they have
    /// fully unwound (cancelling the dispatch kills the agent CLI's process group), their result is
    /// discarded, and the Attempt ends `aborted`. Outer cancellation cancels both and propagates, so
    /// it still wins over an abort.
    func runPassesWatchingForOperatorAbort(frame: CardRunFrame) async throws -> CardRunEnd {
        guard let attemptID = frame.attempt?.id else { return try await runPasses(frame: frame) }
        let journal = frame.journal
        let poll = operatorAbortPoll
        return try await withThrowingTaskGroup(of: CardRunEnd?.self) { group in
            group.addTask { try await runPasses(frame: frame) }
            group.addTask {
                while true {
                    try await Task.sleep(for: poll)
                    if try journal.isOperatorAbortRequested(attemptID: attemptID) { return nil }
                }
            }
            let first: CardRunEnd? = try await group.next().flatMap { $0 }
            group.cancelAll()
            if let end = first { return end }
            // The body has to unwind completely before the Attempt is ended; its value or error is moot.
            do { for try await _ in group {} } catch {}
            return .ending(.aborted)
        }
    }

    /// The Operator's abort was honoured (spec: app/stop-the-engine-for-a-project): the Attempt ends
    /// `aborted`, and the Card Blocks on the Block Reason the epoch's last Attempt yields, `operator
    /// abort`. The Card is reclaimable, and no partial state was written as if it were complete. No
    /// reset runs and no failure cause is recorded: an abort is not a failure, and Worktree
    /// reconciliation at the next Act start handles whatever the killed process group left.
    func concludeAborted(frame: CardRunFrame) async throws -> CardRunAction {
        guard let attempt = frame.attempt else { return .stop }
        try endAttempt(.aborted, frame: frame)
        let reason = try frame.journal.attemptHistory(cardID: frame.card.id).blockReason(inEpoch: attempt.budgetEpoch)
        try frame.revalidateLease()
        try await frame.transition(.blocked(reason))
        try frame.record(.operatorAborted, detail: "attempt \(attempt.id)")
        return .stop
    }
}
