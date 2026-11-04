import Domain
import Foundation
import Journal
import Repositories

extension CardRun {
    /// The commit the worker reported, resolved in the Worktree it ran in (issue #727). The report is
    /// model-authored and may name no commit at all; then the Worktree's HEAD is used in its place and
    /// `cardReportedCommitUnresolved` records both. A short sha is widened to the full one. When neither
    /// resolves (a work tree with no commit) the report is kept as written, and the trailer read records
    /// it unread. Recorded only: it never changes the Card's outcome and never creates a Round.
    func resolveReportedCommit(_ reported: String, attemptID: Int64, frame: CardRunFrame) async throws -> String {
        switch await ReportedCommitResolver(git: git).resolve(reported, worktreePath: frame.worktree.path) {
        case .resolved(let commit):
            return commit
        case .unresolvable:
            return reported
        case .substitutedHead(let head):
            let act = frame.context.act
            try frame.journal.append(
                .cardReportedCommitUnresolved(
                    cardID: frame.card.id, issueID: frame.card.issueID, attemptID: attemptID,
                    reported: reported, resolved: head
                ),
                act: act.act, runID: act.runID, nightID: act.night.id
            )
            return head
        }
    }

    /// After a worker reports a commit, reads LKG..commit with `git log` and records each commit missing
    /// the `Yellowhammer-Work-Card` trailer (graph-execution/run-a-card). Recorded only: it never changes the
    /// Card's outcome, never creates a Round and never touches the board. A commit already recorded for
    /// this Card is not recorded again, so a later Round re-reading the same range adds nothing. When git
    /// cannot read the commits that is recorded instead (`cardCommitTrailersUnread`): a git failure never
    /// throws out of the worker pass. A Journal write that fails is an engine fault, as everywhere else.
    func recordMissingTrailers(commit: String, attemptID: Int64, frame: CardRunFrame) async throws {
        let journal = frame.journal
        let worktree = try journal.heldWorktree(
            featureID: frame.context.feature.id, repository: frame.card.repository
        ) ?? frame.worktree
        let outcome = await commitTrailers.commitsMissingWorkCardTrailer(
            worktreePath: worktree.path, from: worktree.lastKnownGoodCommit, to: commit
        )
        let act = frame.context.act
        switch outcome {
        case .failure(let failure):
            try journal.append(
                .cardCommitTrailersUnread(
                    cardID: frame.card.id, issueID: frame.card.issueID, attemptID: attemptID, commit: commit,
                    reason: failure.reason
                ),
                act: act.act, runID: act.runID, nightID: act.night.id
            )
        case .success(let missing):
            let recorded = try journal.commitsRecordedMissingTrailer(cardID: frame.card.id)
            for sha in missing where !recorded.contains(sha) {
                try journal.append(
                    .cardCommitTrailerMissing(
                        cardID: frame.card.id, issueID: frame.card.issueID, attemptID: attemptID, commit: sha
                    ),
                    act: act.act, runID: act.runID, nightID: act.night.id
                )
            }
        }
    }
}
