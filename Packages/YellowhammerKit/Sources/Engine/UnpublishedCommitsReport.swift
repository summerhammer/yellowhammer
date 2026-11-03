import Domain
import Foundation
import Journal
import Repositories

/// The "not published" report (spec: landing/open-one-pull-request-per-repository, `#unpublished-commits-pin`;
/// OQ191 items 1, 2, 5, 6 and 9; OQ194 item 3): a held Worktree whose HEAD is not its repository's recorded commit,
/// reported when Verification runs, again when the land Act pins that HEAD before release, and before cancellation
/// releases the Worktree. Each is a note, never a failure, and starts "Not published:". The release and cancellation
/// reports never rewrite the Verification-time report: each is its own comment, under its own Outbox key, on the
/// Feature Card and on each Work Card of the lane, and its own Journal event, from which the Night Summary renders
/// the same text.
enum UnpublishedCommitsReport {
    /// When the report is made.
    enum Kind: String {
        /// When Verification runs: nothing is pinned yet.
        case verification
        /// Before the Worktree is released, once its HEAD is pinned.
        case release
        /// Before cancellation releases the Worktree, once its HEAD is pinned.
        case cancellation
    }

    /// What differs: the commits after the recorded commit, or a HEAD that does not descend from it.
    static func whatDiffers(_ unpublished: UnpublishedHead) -> String {
        let recorded = unpublished.noPushedBranch ? "recorded base commit" : "Pushed Tip"
        let recordedCommit = GitCommit.short(unpublished.recordedCommit)
        let head = GitCommit.short(unpublished.head)
        guard let commits = unpublished.commitsAfter else {
            return "the Worktree's HEAD in \(unpublished.repository), \(head), differs from the "
                + "\(recorded) \(recordedCommit)"
        }
        let counted = commits == 1 ? "1 commit" : "\(commits) commits"
        return "\(counted) in \(unpublished.repository) after the \(recorded) \(recordedCommit), up to \(head)"
    }

    /// The report made when Verification runs: it names no pin and no pull request.
    static func atVerification(_ unpublished: UnpublishedHead) -> String {
        let judged = GitCommit.short(unpublished.recordedCommit)
        return "Not published: \(whatDiffers(unpublished)). Verification judged \(judged)."
    }

    /// The report made at release, naming the pin.
    static func atRelease(_ unpublished: UnpublishedHead, pinRef: String) -> String {
        let pinned = "Not published: \(whatDiffers(unpublished)); pinned at `\(pinRef)`."
        if unpublished.noPushedBranch {
            return "\(pinned) \(unpublished.repository) has no pushed branch and no pull request."
        }
        return "\(pinned) The pull request is at \(GitCommit.short(unpublished.recordedCommit))."
    }

    /// The report made at cancellation, naming the pin.
    static func atCancellation(_ unpublished: UnpublishedHead, pinRef: String) -> String {
        "Not published: \(whatDiffers(unpublished)); pinned at `\(pinRef)` before the Feature was cancelled. "
            + "The pinned commits are yours: Yellowhammer never pushes them or deletes the pin."
    }

    /// The report a Journal event records; nil for any other event.
    static func text(of event: JournalEvent) -> String? {
        switch event {
        case .unpublishedCommitsReported(_, let unpublished):
            atVerification(unpublished)
        case .unpublishedCommitsPinned(_, let unpublished, let pinRef):
            atRelease(unpublished, pinRef: pinRef)
        case .unpublishedCommitsPinnedAtCancellation(_, let unpublished, let pinRef):
            atCancellation(unpublished, pinRef: pinRef)
        case .uncommittedChangesSnapshotted(_, let snapshot):
            Self.snapshot(snapshot)
        default:
            nil
        }
    }

    /// "2 modified and 1 untracked file", "1 modified file", "3 untracked files".
    static func snapshotCounts(modified: Int, untracked: Int) -> String {
        func files(_ count: Int) -> String { count == 1 ? "file" : "files" }
        switch (modified, untracked) {
        case (_, 0): return "\(modified) modified \(files(modified))"
        case (0, _): return "\(untracked) untracked \(files(untracked))"
        default: return "\(modified) modified and \(untracked) untracked \(files(modified + untracked))"
        }
    }

    // draft-based: engine wording; the ruling fixes only that the report names the ref as not published
    /// The report made when uncommitted changes were saved as a snapshot before the Worktree was released.
    static func snapshot(_ saved: UncommittedChangesSnapshot) -> String {
        let counts = snapshotCounts(modified: saved.modified, untracked: saved.untracked)
        let verb = saved.modified + saved.untracked == 1 ? "was" : "were"
        let moment = saved.atCancellation ? "the Feature was cancelled" : "the Worktree was released"
        return "Not published: \(counts) in `\(saved.repository)` \(verb) saved as a snapshot at `\(saved.ref)` "
            + "(\(GitCommit.short(saved.commit))) before \(moment). "
            + "The snapshot is yours: Yellowhammer never pushes it or deletes the ref."
    }

    /// Posts the snapshot report at `placement`. The key carries the snapshot commit: a changed snapshot posts
    /// again, and a retry of the same tree posts nothing.
    static func postSnapshot(
        _ saved: UncommittedChangesSnapshot, at placement: LandCommentPlacement, outbox: Outbox?
    ) async {
        let moment = saved.atCancellation ? "cancellation" : "release"
        await placement.post(
            snapshot(saved), keySuffix: "snapshot-\(moment):\(GitCommit.short(saved.commit))", outbox: outbox
        )
    }

    /// Posts `body` at `placement`. One key per Cycle, repository and kind: a later firing posts nothing again.
    static func post(_ body: String, kind: Kind, at placement: LandCommentPlacement, outbox: Outbox?) async {
        await placement.post(body, keySuffix: "unpublished-\(kind.rawValue)", outbox: outbox)
    }
}

extension UnpublishedHead {
    /// What differs for `relation`; nil when HEAD is the recorded commit or could not be read.
    init?(
        _ relation: WorktreeHeadRelation, repository: String, recordedCommit: String, noPushedBranch: Bool
    ) {
        switch relation {
        case .after(let commits, let head):
            self.init(
                repository: repository, recordedCommit: recordedCommit, head: head, commitsAfter: commits,
                noPushedBranch: noPushedBranch
            )
        case .differs(let head):
            self.init(
                repository: repository, recordedCommit: recordedCommit, head: head, commitsAfter: nil,
                noPushedBranch: noPushedBranch
            )
        case .atRecordedCommit, .unreadable:
            return nil
        }
    }
}
