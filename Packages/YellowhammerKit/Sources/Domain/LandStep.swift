/// One step of the land Act's sequence (roadmap P10.1), as the event log records it. Per Repo Lane:
/// merge test, push, open pull request, release Worktree. Per Feature: Verification, return the
/// Feature, archive the Cycle.
public enum LandStep: String, CaseIterable, Sendable {
    case mergeTest = "merge-test"
    case push
    case openPullRequest = "open-pull-request"
    case releaseWorktree = "release-worktree"
    case verification
    case returnFeature = "return-feature"
    case archiveCycle = "archive-cycle"
}

/// What a `landStep` event's step yielded.
public enum LandStepOutcome: String, CaseIterable, Sendable {
    /// The step ran and did what it was for.
    case completed
    /// No seam has landed yet for this step (a later roadmap phase wires it in).
    case notWired = "not-wired"
    /// This step is one of the two rehearsal boundaries (push, open pull request): a rehearsal Night
    /// never calls it.
    case rehearsalBoundary = "rehearsal-boundary"
    /// The step was not attempted because an earlier step in its sequence did not put it in a state
    /// this step needs (e.g. a Worktree released before its lane's Feature Branch was pushed).
    case skipped
    /// The step ran but did not succeed; not necessarily an engine fault — a push seam reporting "not
    /// pushed" is a first-class outcome here, not a throw.
    case failed
}
