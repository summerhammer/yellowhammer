/// One repository's checkout as a Cycle's Verification judged it (spec: verification/verify-a-feature-clause-by-clause,
/// `#judged-checkout`; OQ191 items 3, 5 and 7): the commit judged, the kind of checkout it was judged in, and
/// whether the repository had the No-Pushed-Branch Outcome, in which case the commit is its recorded base commit.
public struct JudgedCheckout: Equatable, Sendable {
    /// The kind of checkout judged (item 7), so a verdict that differs between the two can be explained.
    public enum Kind: String, Equatable, Sendable {
        /// The repository's held Worktree, exact at the recorded commit and clean.
        case heldWorktree = "held-worktree"
        /// A checkout the engine made at the recorded commit, in a new shared layout.
        case freshCheckout = "fresh-checkout"
    }

    public let repository: String
    /// The full SHA judged: the Pushed Tip, or the recorded base commit when `noPushedBranch`.
    public let commit: String
    public let kind: Kind
    /// Marked "no pushed branch" (item 5): the repository has the No-Pushed-Branch Outcome.
    public let noPushedBranch: Bool

    public init(repository: String, commit: String, kind: Kind, noPushedBranch: Bool) {
        self.repository = repository
        self.commit = commit
        self.kind = kind
        self.noPushedBranch = noPushedBranch
    }
}
