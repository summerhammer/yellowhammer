/// Whether a CLI's latest Probe Result offers it as a route target.
public enum RouteTargetEligibility: Equatable, Sendable {
    /// The CLI's latest Probe Result passed: it may be routed to.
    case offered
    /// The CLI is not offered as a route target, and why (Operator-facing).
    case excluded(reason: String)
}
