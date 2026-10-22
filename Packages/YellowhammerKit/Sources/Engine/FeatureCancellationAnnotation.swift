import Journal

/// Board cancellation is disposition, never merge evidence or a change to the Unmerged Feature Stack.
public enum FeatureCancellationAnnotation {
    public static let note = "[canceled on the Board: still unmerged and still counted — "
        + "to drop its changes, merge with a merge commit, then revert; "
        + "to stop it being rebuilt, change the specification]"

    static func suffix(featureID: Int64, issueID: String, journal: JournalStore) throws -> String {
        guard try journal.featureBoardObservation(issueID: issueID)?.workflowState.isShelved == true,
              try journal.unmergedFeatureStack().contains(where: { $0.feature.id == featureID }) else { return "" }
        return " " + note
    }
}
