/// An advisory transcript check before resuming a session. Unsupported CLIs stay silent.
public enum SessionForeignTurnsCheck: Equatable, Sendable {
    case unsupported
    case clean
    case foreignTurns(userCount: Int, assistantCount: Int, firstTimestamp: String?)
    case couldNotCheck(reason: String)

    public var hasForeignTurns: Bool {
        if case .foreignTurns = self { true } else { false }
    }
}
