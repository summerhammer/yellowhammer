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
    /// The final Attempt of the epoch was aborted by the Operator, directly or through Stop the engine.
    /// Distinct from `engine stop`, which stays reserved for involuntary faults; re-ready resets it
    /// exactly like `engine stop`.
    case operatorAbort = "operator abort"
    case unanswered = "unanswered"
    case undecided = "undecided"
    /// Unfinished work carried forward when its still-running Feature is released.
    case released = "released"
    /// The Journal stopped retrying the Card because its failure cause recurred across separate Nights
    /// (Failure-Cause Recurrence; OQ127). Names why retrying stopped, not how the final Attempt ended:
    /// it replaces the reason that Attempt's ending would have given, and wins over a spent Attempt
    /// budget on the same Attempt.
    case failureRecurrence = "failure recurrence"
}
