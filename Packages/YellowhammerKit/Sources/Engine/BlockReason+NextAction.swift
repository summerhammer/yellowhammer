import Domain

extension BlockReason {
    /// What the Operator does next for a Card Blocked for this reason, in a lower-case clause with no
    /// closing full stop. Block Reason is not a label (Board Simplification Ruling 2026-10-20); the
    /// Card's Managed Block states the precise cause and this next action first
    /// (board-projection/maintain-the-managed-block). Exhaustive on purpose: a new case must say what
    /// the Operator does about it before the engine compiles.
    public var nextAction: String {
        switch self {
        case .reviewerRejection:
            "read the reviewer's findings under Attempts, then move the Card back to Todo to retry"
        case .checkFailure:
            "read the failing Check under Attempts, then move the Card back to Todo to retry"
        case .routeFailure:
            "check the Routing Table and the agent CLI, then move the Card back to Todo to retry"
        case .hostCrash:
            "the Card is reclaimable; move it back to Todo to retry"
        case .engineFault:
            "the Card is reclaimable; move it back to Todo to retry"
        case .operatorAbort:
            "move the Card back to Todo to retry the aborted work"
        case .replyOverdue:
            "answer the Card's question in Linear, then move it back to Todo"
        case .decisionOverdue:
            "make the decision the Card waits on, then move it back to Todo"
        case .featureAbandoned:
            "a later Feature may adopt this Card with its history; cancel the Card to drop the work"
        case .featureCompleted:
            "a later Feature may adopt this Card with its history; cancel the Card to drop the unfinished work"
        case .failureRecurrence:
            "fix the cause that recurred across Nights, then move the Card back to Todo"
        case .authoringDefect:
            "correct the Card's brief or Definition of Done, then move it back to Todo"
        }
    }

    /// A sentence the Managed Block states right after the headline, for the Block Reasons whose cause
    /// is the Feature's disposition rather than the Card's own work; nil for the rest.
    public var blockedNote: String? {
        switch self {
        case .featureCompleted: "Feature completed on Board; unfinished work carried forward."
        default: nil
        }
    }

    /// What the Operator does next for a Feature Card Blocked by an expired Authoring Halt (roadmap P22.5; spec:
    /// feature-authoring/select-the-next-feature, `#halted-authoring-repair`): the Card's own next action reads
    /// "answer the Card's question", which is not what a halted Feature waits for.
    public static let haltedFeatureNextAction =
        "repair this Feature (and its Cards) in Linear, then move it to Todo to have it validated and resumed"

    /// The first line of a Blocked halted Feature Card's Managed Block: its Block Reason and the repair to make.
    public static var haltedFeatureHeadline: String {
        "**Blocked — \(BlockReason.replyOverdue.rawValue).** Next: \(haltedFeatureNextAction)"
    }

    /// The first line of a Blocked Card's Managed Block: the precise reason and the next action.
    public var blockedHeadline: String {
        "**Blocked — \(rawValue).** Next: \(nextAction)"
    }
}
