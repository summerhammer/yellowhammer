/// One step of running a Card to completion (graph-execution/run-a-card, roadmap P8.4), as the event
/// log records it. Architect, worker and reviewer are internals of a run, not actors, so they appear
/// here as passes of one run rather than as anything with an identity of their own.
public enum CardRunStep: String, CaseIterable, Sendable {
    /// This run claimed the Card's Lease.
    case leaseClaimed = "lease-claimed"
    /// Another run held the Card's Lease, so this run skipped the Card without dispatching it.
    case skippedLeaseHeld = "skipped-lease-held"
    /// An Attempt was recorded on the resolved Route.
    case attemptStarted = "attempt-started"
    /// The architect pass ran; the detail is what it yielded.
    case architect
    /// The worker pass ran; the detail is what it yielded.
    case worker
    /// The engine-run Check ran between the worker and the reviewer; the detail is what it yielded.
    case check
    /// The reviewer pass ran; the detail is what it yielded.
    case reviewer
    /// This run released the Card's Lease because the Card's run ended.
    case leaseReleased = "lease-released"
    /// This run lost the Card's Lease mid-run; nothing was written as if it were complete.
    case leaseLost = "lease-lost"
    /// The Round budget ran out with the work still not approved — the run stopped without dispatching the
    /// reviewer again, on either Lens. The detail is the raw value of the Lens whose Round was the last;
    /// the Attempt this step belongs to ends `rounds-exhausted`, and the Card blocks only once the Attempt
    /// budget is spent too. While the Attempt budget still has room, the run dispatches a fresh Attempt on
    /// a different Route (roadmap P8.7) rather than returning the Card to Ready.
    case roundsExhausted = "rounds-exhausted"
    /// The Attempt budget for the Card's current epoch is spent, so the Card Blocks instead of a fresh
    /// Attempt being dispatched (roadmap P8.7). The detail is the Operator-facing consumption account
    /// (``Journal/AttemptHistory/consumption(inEpoch:)``), naming how many Attempts were consumed and by
    /// what: a Route failure, a Crashed-Unknown, or the round budget.
    case attemptsExhausted = "attempts-exhausted"
    /// The same failure cause recurred across separate Nights, so the Card was promoted to Triage
    /// instead of a fresh Attempt being dispatched, even with Attempt budget left
    /// (loop-state/record-failure-cause-recurrence, roadmap P8.8). The detail is the Operator-facing
    /// reason: the cause and how many Nights met it.
    case promotedToTriage = "promoted-to-triage"
    /// The fence → WIP-commit → preserve → reset sequence ran before a new Attempt or a Block
    /// (Attempt, Block and Reset Ruling 2026-09-19, OQ60): the detail is the preservation ref, or
    /// "nothing to preserve" when the Feature Branch tip already equalled the last known-good commit.
    case attemptReset = "attempt-reset"
    /// The fence → WIP-commit → preserve → reset sequence refused or failed: nothing was destroyed.
    /// Before a retry, the new Attempt is never dispatched and the Card returns to Ready instead; on
    /// a Block path the Card Blocks regardless. The detail is the reason.
    case attemptResetFailed = "attempt-reset-failed"
    /// An architect or worker result reported `failed` carrying `authoring_invariant_violation`
    /// (graph-execution/handle-a-block-mid-graph, P8.9): the Feature was mis-authored, not the Card
    /// misordered. The detail is the reason recorded alongside `.authoringInvariantBroken`.
    case authoringInvariantViolated = "authoring-invariant-violated"
}

/// What one engine-run Check yielded, as the `checkRan` event records it.
public enum CheckRunResult: String, CaseIterable, Sendable {
    case passed
    case failed
    /// The repository declared `check = "none"`: nothing was run.
    case declaredNone = "declared-none"
}
