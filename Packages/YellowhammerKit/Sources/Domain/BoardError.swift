/// Why a board call failed, translated into Yellowhammer's vocabulary.
///
/// A vendor error shape never crosses the Board Port (ADR-001): every message here is written by the
/// adapter, and none carries a credential or token.
public enum BoardError: Error, Equatable, Sendable {
    /// The credentials were refused, or no token could be obtained.
    case notAuthenticated(String)
    /// The board refused the request for its rate limit. The budget named here is workspace-wide,
    /// never this Project's own.
    case rateLimited(retryAfter: Duration?, budget: BoardBudget?)
    /// The Project's Linear project is not visible to this identity.
    case scopeNotFound(String)
    /// The board refused the request for another reason.
    case refused(String)
    /// The board could not be reached.
    case unreachable(String)
    /// The board answered with something that could not be read.
    case unreadableResponse(String)
}

extension BoardError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAuthenticated(let message):
            "the board refused Yellowhammer's identity: \(message)"
        case .rateLimited(let retryAfter, _):
            if let retryAfter {
                "the board's rate limit was reached; retry after \(retryAfter)"
            } else {
                "the board's rate limit was reached"
            }
        case .scopeNotFound(let message):
            "the Project's Linear project is not visible to Yellowhammer's identity: \(message)"
        case .refused(let message):
            "the board refused the request: \(message)"
        case .unreachable(let message):
            "the board could not be reached: \(message)"
        case .unreadableResponse(let message):
            "the board's response could not be read: \(message)"
        }
    }
}
