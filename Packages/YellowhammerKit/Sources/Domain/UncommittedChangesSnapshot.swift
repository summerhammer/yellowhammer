/// The uncommitted changes of a held Worktree, saved as a snapshot under a local ref outside `refs/heads/` before the
/// Worktree was released (spec: landing/open-one-pull-request-per-repository, `#uncommitted-snapshot`; OQ196 item 1).
/// The snapshot is never pushed or published and is the Operator's.
public struct UncommittedChangesSnapshot: Equatable, Sendable {
    public let repository: String
    /// The local ref the snapshot is saved under.
    public let ref: String
    /// The full SHA of the snapshot commit.
    public let commit: String
    /// Files git reported as changed that it already tracked: modified, deleted, renamed or staged.
    public let modified: Int
    /// Untracked files that git does not ignore.
    public let untracked: Int
    /// Saved before cancellation released the Worktree, rather than before the land Act did.
    public let atCancellation: Bool

    public init(
        repository: String, ref: String, commit: String, modified: Int, untracked: Int, atCancellation: Bool
    ) {
        self.repository = repository
        self.ref = ref
        self.commit = commit
        self.modified = modified
        self.untracked = untracked
        self.atCancellation = atCancellation
    }
}
