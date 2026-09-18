/// The repo-level command the engine runs itself before any reviewer sees the diff.
///
/// Required on every Repo: ``none`` is declared explicitly as `check = "none"`, never assumed from silence.
///
/// Accepted cost (risk R6): a flaky Check blocks a Card that nothing was wrong with, and with a round budget
/// of two it does so quickly.
public enum Check: Hashable, Sendable {
    /// Declared as `none`: a green comes from a model alone.
    case none
    case command(String)
}

extension Check: CustomStringConvertible {
    public var description: String {
        switch self {
        case .none: "none"
        case .command(let command): command
        }
    }
}
