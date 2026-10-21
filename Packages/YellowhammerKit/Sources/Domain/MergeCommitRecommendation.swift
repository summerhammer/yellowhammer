/// The merge-commit recommendation and its reason (OQ164; spec: landing/open-one-pull-request-per-repository
/// `#merge-commit-recommendation`). It is a recommendation, not an instruction: every merge method is allowed.
/// A squash or rebase merge is recognised only while mainline still shows the branch's changes. It is never
/// claimed to have happened, and never said to stall the next Feature for good.
public enum MergeCommitRecommendation {
    /// The two sentences that the pull request body and the Night Card's authoring-skip line share word for
    /// word, so that the two cannot drift.
    public static let shared =
        "Merging with **Create a merge commit** always releases the next Feature. "
        + "Squash and merge or Rebase and merge works too, but it is recognised only while mainline "
        + "still shows this branch's changes."

    /// The pull request body's full recommendation: ``shared`` followed by the sentence that only the body
    /// carries.
    public static let pullRequestBody =
        shared + " An edit to the same lines before the next Night holds the next Feature back."
}
