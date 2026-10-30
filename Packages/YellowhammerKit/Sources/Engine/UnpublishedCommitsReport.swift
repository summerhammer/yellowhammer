import Domain
import Foundation
import Journal
import Repositories

/// The "not published" report (spec: landing/open-one-pull-request-per-repository, `#unpublished-commits-pin`;
/// OQ191 items 1, 2, 5, 6 and 9): a held Worktree whose HEAD is not its repository's recorded commit, reported when
/// Verification runs and again when the land Act pins that HEAD before release. Each is a note, never a failure,
/// and starts "Not published:". The release report never rewrites the Verification-time report: each is its own
/// comment, under its own Outbox key, on the Feature Card and on each Work Card of the lane, and its own Journal
/// event, from which the Night Summary renders the same text.
enum UnpublishedCommitsReport {
    /// When the report is made.
    enum Kind: String {
        /// When Verification runs: nothing is pinned yet.
        case verification
        /// Before the Worktree is released, once its HEAD is pinned.
        case release
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

    /// The report a Journal event records; nil for any other event.
    static func text(of event: JournalEvent) -> String? {
        switch event {
        case .unpublishedCommitsReported(_, let unpublished):
            atVerification(unpublished)
        case .unpublishedCommitsPinned(_, let unpublished, let pinRef):
            atRelease(unpublished, pinRef: pinRef)
        default:
            nil
        }
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
