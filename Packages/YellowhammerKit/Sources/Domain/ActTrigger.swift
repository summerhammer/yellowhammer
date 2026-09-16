/// Why an Act is running.
///
/// `launchd` fires Acts on schedule and every firing evaluates its own Act's trigger predicate (P4.3);
/// the Operator can force an Act from the CLI or the app, which overrides that predicate.
public enum ActTrigger: Sendable, Equatable {
    case scheduled
    case forced
    /// The Operator forced the author Act for a Feature they named, overriding selection.
    case forcedForFeature(FeatureName)
}

extension ActTrigger {
    /// Whether this trigger was forced (either explicitly or with a named Feature).
    public var isForced: Bool {
        switch self {
        case .scheduled:
            return false
        case .forced, .forcedForFeature:
            return true
        }
    }

    /// The Feature name if this trigger is `forcedForFeature`, otherwise nil.
    public var namedFeature: FeatureName? {
        switch self {
        case .scheduled, .forced:
            return nil
        case .forcedForFeature(let name):
            return name
        }
    }
}
