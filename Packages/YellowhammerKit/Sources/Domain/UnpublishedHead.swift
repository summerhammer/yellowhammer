/// A held Worktree whose HEAD is not its repository's recorded commit (spec: landing/open-one-pull-request-per-repository,
/// `#unpublished-commits-pin`; OQ191 items 1, 2, 5, 6 and 9): what differs, which the land Act reports as not
/// published. The recorded commit is the repository's Pushed Tip, or its recorded base commit when the repository
/// has the No-Pushed-Branch Outcome.
public struct UnpublishedHead: Equatable, Sendable {
    public let repository: String
    /// The full SHA of the recorded commit: the Pushed Tip, or the recorded base commit when `noPushedBranch`.
    public let recordedCommit: String
    /// The full SHA of the Worktree's HEAD.
    public let head: String
    /// How many commits HEAD is after the recorded commit; nil when HEAD does not descend from it (item 9).
    public let commitsAfter: Int?
    /// The repository has the No-Pushed-Branch Outcome, so `recordedCommit` is its recorded base commit.
    public let noPushedBranch: Bool

    public init(repository: String, recordedCommit: String, head: String, commitsAfter: Int?, noPushedBranch: Bool) {
        self.repository = repository
        self.recordedCommit = recordedCommit
        self.head = head
        self.commitsAfter = commitsAfter
        self.noPushedBranch = noPushedBranch
    }

    /// Whether HEAD descends from the recorded commit.
    public var descends: Bool { commitsAfter != nil }
}
