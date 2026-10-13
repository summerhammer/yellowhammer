/// How the predecessor gate observed a Feature Branch merged into mainline in one repository
/// (feature-authoring/select-the-next-feature, Observed Merge recording criterion). Recorded with the
/// Observed Merge and kept in the Journal only: no board surface, Night Card or pull request text names it.
/// Both kinds count identically for the merged fraction and merge closure.
public enum ObservedMergeEvidence: String, Sendable, Equatable, CaseIterable {
    /// The tested tip is an ancestor of mainline — a merge commit, or a fast-forward.
    case ancestry
    /// The tip is not an ancestor, but mainline still shows its net changes — Squash and merge, or
    /// Rebase and merge.
    case content
}
