/// The stack notice of a stacked pull request (spec: landing/open-one-pull-request-per-repository
/// `#stack-notice`; agent rulings 2026-10-21 item 4, pending sponsor review). A pull request is stacked when
/// `effective_base(R)`, computed at landing from the Unmerged Feature Stack U as it then stands, is a
/// predecessor Feature's Feature Branch. Pure value: the caller (``FeatureBranchPullRequest``) reads the
/// Journal.
public struct PullRequestStackNotice: Equatable, Sendable {
    /// The predecessor's pull request number in this repository, from its recorded `pull_request` URL; nil
    /// when the Journal records none (or GitHub reported it already open, so no URL was recorded).
    public let predecessorPullRequestNumber: Int?
    /// `<b_last>`: the predecessor's Feature Branch, which is this pull request's `base`.
    public let predecessorBranch: String
    /// `<prev_feature>`: the predecessor Feature's display identifier, never an issue id.
    public let predecessorFeature: String
    /// `<default_branch>`: the repository's default branch.
    public let defaultBranch: String

    public init(
        predecessorPullRequestNumber: Int?, predecessorBranch: String, predecessorFeature: String,
        defaultBranch: String
    ) {
        self.predecessorPullRequestNumber = predecessorPullRequestNumber
        self.predecessorBranch = predecessorBranch
        self.predecessorFeature = predecessorFeature
        self.defaultBranch = defaultBranch
    }

    /// The pull request number at the end of a recorded GitHub pull request URL
    /// (`https://github.com/<owner>/<repo>/pull/<n>`), or nil when the URL has no such suffix.
    public static func pullRequestNumber(fromURL url: String?) -> Int? {
        guard let url else { return nil }
        let parts = url.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[parts.count - 2] == "pull" else { return nil }
        return Int(parts[parts.count - 1])
    }

    /// The notice, word for word from the story, with the placeholders filled. When the predecessor has no
    /// recorded pull request number, "the predecessor's pull request" stands in for `#<prev_pr>`.
    public var rendered: String {
        let named = predecessorPullRequestNumber.map { "#\($0)" } ?? "the predecessor's pull request"
        return "Stacked on \(named) (`\(predecessorBranch)`) from Feature \(predecessorFeature). "
            + "Merge \(named) first. "
            + "Merging this one first merges it into `\(predecessorBranch)`, not `\(defaultBranch)`: "
            + "it reaches mainline when \(named) merges, and both then count. "
            + "If \(named) has merged and this pull request still targets `\(predecessorBranch)`, "
            + "change its base to `\(defaultBranch)` before merging."
    }
}
