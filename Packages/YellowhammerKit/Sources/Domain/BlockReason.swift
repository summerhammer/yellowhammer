/// The values a Blocked Card's Block Reason takes, distinguishing blocked-by-check from
/// blocked-by-reviewer and a hard failure from a host crash; a Cancelled Card carries none.
public enum BlockReason: String, CaseIterable, Sendable {
    case blockedByReviewer = "blocked by reviewer"
    case blockedByCheck = "blocked by check"
    case hardFailure = "hard failure"
    /// The final Attempt of the epoch ended Crashed-Unknown: a dying host, not the model's fault
    /// (Attempt, Block and Reset Ruling 2026-09-19, OQ59). The spec leaves the raw value unnamed;
    /// this repo's follows the spec's own descriptor, "host crash".
    case hostCrash = "host crash"
    case unanswered = "unanswered"
    case undecided = "undecided"
    /// Unfinished work carried forward when its still-running Feature is released.
    case released = "released"
}
