/// The value of the Night Summary's constant-time verdict line, as the Journal records it.
///
/// `idle` is the one verdict this phase writes: the author Act finding nothing selectable
/// (`AuthoringNoWorkAvailable`, OQ13). Every other verdict arrives with the Night Summary (P12.1);
/// until then a Night with no verdict completes its Night Card with a placeholder.
public enum NightVerdict: String, CaseIterable, Sendable {
    case idle
}
