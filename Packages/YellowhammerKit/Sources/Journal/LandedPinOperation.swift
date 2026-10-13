/// Which half of a landed-tip pin's life failed: writing the pin at the push, or deleting it when the
/// Feature was Abandoned (``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)``).
public enum LandedPinOperation: String, Sendable, Equatable {
    case pin
    case unpin
}
