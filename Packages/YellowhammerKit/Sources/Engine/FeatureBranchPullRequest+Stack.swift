import Domain
import Journal

/// A stacked pull request's base (spec: landing/open-one-pull-request-per-repository `#stack-notice`; OQ177):
/// the predecessor Feature in the Unmerged Feature Stack U this pull request is opened against, its recorded
/// pull request in the same repository, and the notice the body carries.
struct StackedPullRequestBase {
    let predecessor: EffectiveBase
    let predecessorPullRequestURL: String?
    let notice: PullRequestStackNotice
}

extension FeatureBranchPullRequest {
    /// `effective_base(R)` **computed at landing from U as it then stands**, excluding the Feature being
    /// landed. Nil means the pull request opens against `defaultBranch`. Never read from the Feature's
    /// recorded base (`feature_base`): a predecessor that merged while this Feature was in flight has left U,
    /// and GitHub may already have deleted its branch (agent ruling 2026-10-21 item 11, pending sponsor
    /// review). Reads the Journal only; no git and no GitHub.
    func stackedBase(context: LandActLaneContext, defaultBranch: String) throws -> StackedPullRequestBase? {
        let journal = context.act.journal
        let repository = context.lane.repository
        guard let predecessor = try journal.effectiveBase(
            repository: repository, excludingFeatureID: context.feature.id
        ) else {
            return nil
        }
        let predecessorURL = try journal.pullRequest(featureID: predecessor.featureID, repository: repository)?.url
        let predecessorFeature = try journal.feature(id: predecessor.featureID)?.displayIdentifier
            ?? predecessor.featureIssueID
        let notice = PullRequestStackNotice(
            predecessorPullRequestNumber: PullRequestStackNotice.pullRequestNumber(fromURL: predecessorURL),
            predecessorBranch: predecessor.branch.name,
            predecessorFeature: predecessorFeature,
            defaultBranch: defaultBranch
        )
        return StackedPullRequestBase(
            predecessor: predecessor, predecessorPullRequestURL: predecessorURL, notice: notice
        )
    }

    /// Records the stack base right after the pull request row, so the Night Summary can name the predecessor's
    /// pull request. Best-effort, like the pull request row itself.
    func recordStacked(_ stacked: StackedPullRequestBase, laneContext: LandActLaneContext) {
        _ = try? laneContext.act.journal.append(
            .pullRequestStacked(
                featureIssueID: laneContext.feature.issueID, repository: laneContext.lane.repository,
                predecessorFeatureIssueID: stacked.predecessor.featureIssueID,
                predecessorBranch: stacked.predecessor.branch.name,
                predecessorPullRequestURL: stacked.predecessorPullRequestURL
            ),
            act: laneContext.act.act, runID: laneContext.act.runID, nightID: laneContext.act.night.id
        )
    }
}
