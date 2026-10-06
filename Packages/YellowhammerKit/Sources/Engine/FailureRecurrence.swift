/// A Card Blocked under `failure recurrence` by Failure-Cause Recurrence, as its board projection words
/// it (loop-state/record-failure-cause-recurrence, roadmap P8.8; OQ127): the cause, and how many separate
/// Nights met it, so the morning reads the Card as a design conversation rather than a rerun.
public struct FailureRecurrence: Equatable, Sendable {
    /// The Operator-facing name of the failure cause (``Domain/FailureCause/summary``).
    public var cause: String
    /// How many separate Nights of this Project met the cause.
    public var nights: Int

    public init(cause: String, nights: Int) {
        self.cause = cause
        self.nights = nights
    }

    /// The reason the `blocked-on-failure-recurrence` step and the Managed Block both carry.
    public var reason: String {
        "failure cause `\(cause)` recurred across \(nights) Nights — a design conversation, not a rerun"
    }
}
