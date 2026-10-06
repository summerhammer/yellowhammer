/// The values a Blocked Card's Block Reason takes, each naming why the Card stopped: a
/// `reviewer rejection` or a `check failure` once the Round budget is spent, a `route failure` when
/// the final Attempt hard-failed, a `host crash` or an `engine fault` when it ended Crashed-Unknown,
/// an `operator abort`, a `reply overdue` or `decision overdue` once the unanswered-Nights bound
/// fires, a `feature abandoned` when its still-running Feature is released, and a
/// `failure recurrence` when the same failure cause recurred across Nights; a Cancelled Card
/// carries none.
public enum BlockReason: String, CaseIterable, Sendable {
    case reviewerRejection = "reviewer rejection"
    case checkFailure = "check failure"
    case routeFailure = "route failure"
    /// The final Attempt of the epoch ended Crashed-Unknown: a dying host, not the model's fault
    /// (Attempt, Block and Reset Ruling 2026-09-19, OQ59). The spec leaves the raw value unnamed;
    /// this repo's follows the spec's own descriptor, "host crash".
    case hostCrash = "host crash"
    /// The final Attempt of the epoch ended Crashed-Unknown, and its run recorded that the engine
    /// stopped it and left its Lease to expire, rather than a dying host (OQ92).
    case engineFault = "engine fault"
    /// The final Attempt of the epoch was aborted by the Operator, directly or through Stop the engine.
    /// Distinct from `engine fault`, which stays reserved for involuntary faults; re-ready resets it
    /// exactly like `engine fault`.
    case operatorAbort = "operator abort"
    case replyOverdue = "reply overdue"
    case decisionOverdue = "decision overdue"
    /// Unfinished work carried forward when its still-running Feature is released.
    case featureAbandoned = "feature abandoned"
    /// The Journal stopped retrying the Card because its failure cause recurred across separate Nights
    /// (Failure-Cause Recurrence; OQ127). Names why retrying stopped, not how the final Attempt ended:
    /// it replaces the reason that Attempt's ending would have given, and wins over a spent Attempt
    /// budget on the same Attempt.
    case failureRecurrence = "failure recurrence"
}
