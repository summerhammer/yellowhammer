import Domain
import Journal

// The narrow re-ready exception (roadmap P11.4; spec: bounds/bound-unanswered-nights), split out of
// DeltaRead.swift to keep that file under the type-length limit. A Card the Journal Blocked
// `unanswered` or `undecided` (the unanswered-Nights bound's own two reasons), read back as Todo, is
// the Operator's re-ready rather than a board write to restate: budget_epoch, attempts, rounds and
// exclusions are untouched, only the state moves. Every other Block Reason keeps `reconcileState`'s
// ordinary restate behavior.

extension DeltaRead {
    /// Returns `true`, and appends `card` to `report.reReadied`, when `card` qualifies for the
    /// re-ready exception; `false` otherwise, leaving `card` and `report` untouched.
    func reReadyIfUnansweredBlock(
        card: inout CardRecord, boardState: BoardWorkflowState, into report: inout DeltaReadReport
    ) throws -> Bool {
        guard card.state == .blocked, boardState.name == CardState.todo.rawValue,
              let blockReason = card.blockReason,
              blockReason == BlockReason.unanswered.rawValue || blockReason == BlockReason.undecided.rawValue
        else {
            return false
        }
        card = try journal.transitionCard(
            cardID: card.id, to: .todo, runID: runID, act: act, nightID: nightID, now: clock()
        )
        report.reReadied.append(card)
        return true
    }
}
