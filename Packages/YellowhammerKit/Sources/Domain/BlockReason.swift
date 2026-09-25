/// The values a Blocked Card's Block Reason takes, distinguishing blocked-by-check from
/// blocked-by-reviewer, a hard failure from a host crash, and a host crash from the engine
/// deliberately stopping the run; a Cancelled Card carries none.
public enum BlockReason: String, CaseIterable, Sendable {
    case blockedByReviewer = "blocked by reviewer"
    case blockedByCheck = "blocked by check"
    case hardFailure = "hard failure"
    /// The final Attempt of the epoch ended Crashed-Unknown: a dying host, not the model's fault
    /// (Attempt, Block and Reset Ruling 2026-09-19, OQ59). The spec leaves the raw value unnamed;
    /// this repo's follows the spec's own descriptor, "host crash".
    case hostCrash = "host crash"
    /// The final Attempt of the epoch ended Crashed-Unknown, and its run recorded that the engine
    /// stopped it and left its Lease to expire, rather than a dying host (OQ92).
    case engineStop = "engine stop"
    case unanswered = "unanswered"
    case undecided = "undecided"
    /// Unfinished work carried forward when its still-running Feature is released.
    case released = "released"
}
