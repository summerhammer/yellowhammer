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
    /// The Round budget ran out with the work still red: the run stopped without dispatching the reviewer.
    /// The detail is the raw value of the Lens whose Round was the last. Blocking the Card is P8.6/P8.7.
    case roundsExhausted = "rounds-exhausted"
}

/// What one engine-run Check yielded, as the `checkRan` event records it.
public enum CheckRunResult: String, CaseIterable, Sendable {
    case passed
    case failed
    /// The repository declared `check = "none"`: nothing was run.
    case declaredNone = "declared-none"
}
