/// What the Operator-facing copy says about merging a Feature's pull request (OQ190 items 3 and 6). It recommends no
/// merge method.
enum MergeRouteOut {
    /// Shared word for word by the pull request body and the Night Card lines for a Feature awaiting merge, so the
    /// two cannot drift (spec: landing/open-one-pull-request-per-repository `#any-merge-method`,
    /// morning-report/write-the-night-summary `#stack-full-skip`).
    static let anyMethod = "Merging the pull request by any method releases the next Feature."

    /// The route out for a merge the gate cannot see (feature-authoring/select-the-next-feature `#route-out`). The
    /// Night Card's stack-full skip line and each standing-line entry in U carry it
    /// (morning-report/write-the-night-summary `#unmerged-standing-line`); the pull request body never does.
    static let contentFreeMerge =
        "If the pull request is already merged and the Feature is still waiting, a content-free merge of the "
        + "Feature Branch into mainline with a merge commit (`git merge -s ours`) opens the gate."

    /// ``anyMethod`` then ``contentFreeMerge``: the Night Card's wording for a Feature awaiting merge.
    static let nightCard = anyMethod + " " + contentFreeMerge
}
