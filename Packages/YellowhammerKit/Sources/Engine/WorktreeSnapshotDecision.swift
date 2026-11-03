import Domain
import Foundation
import Repositories

/// What saving a present git Worktree's uncommitted changes before release decided, for both the land Act and
/// cancellation (spec: landing/open-one-pull-request-per-repository, `#uncommitted-snapshot`; OQ196 item 1). The same
/// rule applies on a Rehearsal Night, so nothing here reads the Night's mode.
enum WorktreeSnapshotDecision {
    /// Nothing is uncommitted, or an earlier firing already saved this tree: release.
    case nothingToSave
    /// The changes were saved: release, and report the snapshot.
    case saved(UncommittedChangesSnapshot)
    /// The changes could not be saved: the Worktree stays held; `comment` says why.
    case keepHeld(comment: (body: String, keySuffix: String))

    static func evaluate(
        worktreePath: String, repository: String, branch: FeatureBranch?, moment: LandFailureComment.Moment,
        snapshot: UncommittedSnapshot = UncommittedSnapshot()
    ) async -> WorktreeSnapshotDecision {
        let path = (worktreePath as NSString).expandingTildeInPath
        guard let branch else {
            switch await snapshot.isDirty(worktreePath: path) {
            case .clean:
                return .nothingToSave
            case .dirty:
                return .keepHeld(
                    comment: LandFailureComment.snapshotWithoutBranch(repository: repository, moment: moment)
                )
            case .failed(let reason):
                return .keepHeld(
                    comment: LandFailureComment.snapshotFailed(repository: repository, reason: reason, moment: moment)
                )
            }
        }
        switch await snapshot.snapshot(worktreePath: path, branch: branch) {
        case .clean, .alreadySnapshotted:
            return .nothingToSave
        case .snapshotted(let ref, let commit, let modified, let untracked, _):
            return .saved(
                UncommittedChangesSnapshot(
                    repository: repository, ref: ref, commit: commit, modified: modified, untracked: untracked,
                    atCancellation: moment == .cancellation
                )
            )
        case .failed(let reason):
            return .keepHeld(
                comment: LandFailureComment.snapshotFailed(repository: repository, reason: reason, moment: moment)
            )
        }
    }
}
