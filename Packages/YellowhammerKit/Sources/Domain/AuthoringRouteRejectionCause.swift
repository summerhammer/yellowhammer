/// Why one authoring Route failed in an author Act's walk (the `AuthoringRouteRejected` event): the
/// class the Night Card groups its per-Route lines by.
public enum AuthoringRouteRejectionCause: String, Sendable, CaseIterable {
    case overDescriptionBudget = "over_description_budget"
    case invalidOutput = "invalid_output"
    case reportedFailed = "reported_failed"
    case unavailable
    case exited
    case brokeResultContract = "broke_result_contract"
    case timedOut = "timed_out"

    /// The cause as the Night Card words it, after the Route name.
    public var phrase: String {
        switch self {
        case .overDescriptionBudget: "over the description budget"
        case .invalidOutput: "invalid output"
        case .reportedFailed: "reported failed"
        case .unavailable: "unavailable"
        case .exited: "exited"
        case .brokeResultContract: "broke the result contract"
        case .timedOut: "ran out of time"
        }
    }
}
