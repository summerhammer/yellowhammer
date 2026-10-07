import Domain
import Journal

// Re-ready (bounds/bound-review-rounds-and-attempts): Linear Todo accepts a Journal-Blocked
// Card with a known Block Reason. Spent automatic effort starts a new budget epoch; overdue
// replies, overdue decisions and abandoned Features preserve their budgets and exclusions.

extension DeltaRead {
    /// Accepts the Operator's re-ready. The caller has already ruled out pending board writes.
    func reReadyIfBlocked(
        card: inout CardRecord, boardState: BoardWorkflowState, into report: inout DeltaReadReport
    ) throws -> Bool {
        guard card.state == .blocked, boardState.name == CardState.todo.rawValue,
              let rawReason = card.blockReason, let reason = BlockReason(rawValue: rawReason)
        else {
            return false
        }
        card = try journal.transitionCard(
            cardID: card.id, to: .todo,
            resetBudgetReason: reason.resetsBudgetOnReReady ? "re-readied" : nil,
            runID: runID, act: act, nightID: nightID, now: clock()
        )
        report.reReadied.append(card)
        return true
    }
}
