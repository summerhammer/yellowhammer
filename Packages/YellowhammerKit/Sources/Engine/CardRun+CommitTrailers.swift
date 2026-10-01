import Domain
import Foundation
import Journal

extension CardRun {
    /// After a worker reports a commit, reads LKG..commit with `git log` and records each commit missing
    /// the `Yellowhammer-Card` trailer (graph-execution/run-a-card). Recorded only: it never changes the
    /// Card's outcome, never creates a Round and never touches the board. A commit already recorded for
    /// this Card is not recorded again, so a later Round re-reading the same range adds nothing. When git
    /// cannot read the commits that is recorded instead (`cardCommitTrailersUnread`): a git failure never
    /// throws out of the worker pass. A Journal write that fails is an engine fault, as everywhere else.
    func recordMissingTrailers(commit: String, attemptID: Int64, frame: CardRunFrame) async throws {
        let journal = frame.journal
        let worktree = try journal.heldWorktree(
            featureID: frame.context.feature.id, repository: frame.card.repository
        ) ?? frame.worktree
        let outcome = await commitTrailers.commitsMissingCardTrailer(
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
