import Domain
import Journal

/// A Card's board-projected state, in the Engine's vocabulary rather than the raw ``CardState``: what
/// ``BoardStateProjection/transition(card:to:)`` writes to the Journal and the board together. Never
/// Cancelled — Yellowhammer reads it and never writes it.
public enum CardTransition: Equatable, Sendable {
    /// Todo: the Card is ready to dispatch.
    case ready
    case inProgress
    case blocked(BlockReason)
    /// Delivery is the assignment to the Operator (Linear notifies off it); `operator` is the
    /// Operator's board identity, nil when the Operator identity is unconfigured or is no longer an
    /// active workspace member — the state is still written, only the assignment is skipped
    /// (Operator Identity Ruling — 2026-09-23).
    case waitingOnYou(WaitingReason, operator: BoardObjectID?)
    case done

    public var state: CardState {
        switch self {
        case .ready: .todo
        case .inProgress: .inProgress
        case .blocked: .blocked
        case .waitingOnYou: .waitingOnYou
        case .done: .done
        }
    }

    public var blockReason: BlockReason? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }

    public var waitingReason: WaitingReason? {
        if case .waitingOnYou(let reason, _) = self { return reason }
        return nil
    }
}
