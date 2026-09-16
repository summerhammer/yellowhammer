/// The mutually exclusive group distinguishing blocked-by-check from blocked-by-reviewer; a Cancelled Card carries none.
public enum BlockReason: String, CaseIterable, Sendable {
    case blockedByReviewer = "blocked by reviewer"
    case blockedByCheck = "blocked by check"
    case hardFailure = "hard failure"
    case unanswered = "unanswered"
    case undecided = "undecided"
}
