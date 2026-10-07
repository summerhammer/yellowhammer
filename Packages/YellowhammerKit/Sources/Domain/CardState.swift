/// A Card's workflow state, spelled as Linear spells it and as the glossary's Roll-up lattice
/// names it. The spellings are the vocabulary, so they are the raw values.
///
/// Shelved is the one state Yellowhammer reads and never writes.
public enum CardState: String, CaseIterable, Sendable {
    case todo = "Todo"
    case inProgress = "In Progress"
    case done = "Done"
    case blocked = "Blocked"
    case waitingOnYou = "Waiting on You"
    case shelved = "Shelved"

    /// True for `todo` and `inProgress` only.
    ///
    /// The Roll-up lattice places Blocked and Waiting on You Cards in the "all lanes finished and pushed"
    /// half — that is exactly what a Partial Landing is — so they are not unfinished. A Shelved Card is
    /// explicitly not an unfinished Card and does not hold the land Act shut. Done is finished.
    public var isUnfinished: Bool {
        switch self {
        case .todo, .inProgress:
            true
        case .done, .blocked, .waitingOnYou, .shelved:
            false
        }
    }
}
