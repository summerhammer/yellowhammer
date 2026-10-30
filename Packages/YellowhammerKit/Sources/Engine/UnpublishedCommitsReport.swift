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
        guard let commits = unpublished.commitsAfter else {
            return "the Worktree's HEAD in \(unpublished.repository), \(short(unpublished.head)), differs from the "
                + "\(recorded) \(short(unpublished.recordedCommit))"
        }
        let counted = commits == 1 ? "1 commit" : "\(commits) commits"
        return "\(counted) in \(unpublished.repository) after the \(recorded) \(short(unpublished.recordedCommit)), "
            + "up to \(short(unpublished.head))"
    }

    /// The report made when Verification runs: it names no pin and no pull request.
    static func atVerification(_ unpublished: UnpublishedHead) -> String {
        "Not published: \(whatDiffers(unpublished)). Verification judged \(short(unpublished.recordedCommit))."
    }

    /// The report made at release, naming the pin.
    static func atRelease(_ unpublished: UnpublishedHead, pinRef: String) -> String {
        let pinned = "Not published: \(whatDiffers(unpublished)); pinned at `\(pinRef)`."
        if unpublished.noPushedBranch {
            return "\(pinned) \(unpublished.repository) has no pushed branch and no pull request."
        }
        return "\(pinned) The pull request is at \(short(unpublished.recordedCommit))."
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

    /// Where a repository's report is posted: the Feature Card and each Work Card of the lane that is Done and
    /// still on the board, where a refused push is reported.
    struct Placement {
        let cycleID: Int64
        let repository: String
        let issues: [String]

        init(cycleID: Int64, repository: String, featureIssueID: String, laneCards: [CardRecord]) {
            self.cycleID = cycleID
            self.repository = repository
            issues = [featureIssueID]
                + laneCards.filter { $0.state == .done && !$0.isRemovedFromBoard }.map(\.issueID)
        }
    }

    /// Posts `body` at `placement`. One key per Cycle, repository and kind: a later firing posts nothing again.
    static func post(_ body: String, kind: Kind, at placement: Placement, outbox: Outbox?) async {
        guard let outbox else { return }
        let prefix = "land:\(placement.cycleID):\(placement.repository):unpublished-\(kind.rawValue)"
        for issue in placement.issues {
            let write = OutboxWrite(
                key: "\(prefix):\(issue)", write: .createComment(issue: BoardObjectID(rawValue: issue), body: body)
            )
            _ = try? await outbox.post(write)
        }
    }

    private static func short(_ commit: String) -> String {
        String(commit.prefix(7))
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
