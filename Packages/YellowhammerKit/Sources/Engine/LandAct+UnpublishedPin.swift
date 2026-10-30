import Domain
import Foundation
import Journal
import Repositories

// The unpublished-commits pin (spec: landing/open-one-pull-request-per-repository, `#unpublished-commits-pin`;
// OQ191 items 1, 5, 6 and 9): before the land Act releases a held Worktree whose HEAD is not its repository's
// recorded commit — descendant or not — it pins that HEAD at `refs/yellowhammer/unpublished/<branch>` in the main
// clone, outside `refs/heads/`, which Orca ADE does not delete. The pin is never pushed or published and does not
// block the Cycle from landing; it is reported as not published, naming the pin and the commits. A pin that cannot
// be written keeps the Worktree held: the release step fails and the next land firing retries, so no commit is
// lost to Orca ADE's removal (the lead's decision; not ruled). Uncommitted changes are not covered (OQ196).

/// What the pin before release decided.
enum UnpublishedPinStep {
    /// The Worktree may be released; `detail` names the pin when one was written.
    case release(detail: String?)
    /// The Worktree stays held: the release step fails with this detail.
    case keepHeld(String)
}

extension LandAct {
    /// Pins the held Worktree's HEAD when it is not the recorded commit, and reports it. The recorded commit is the
    /// Pushed Tip for a pushed lane, or the recorded base commit for a lane with the No-Pushed-Branch Outcome. A
    /// lane with neither recorded, or whose Worktree directory is gone (the ghost-Worktree purge's case), has no
    /// HEAD to compare and releases as before.
    func pinUnpublishedHead(
        held: WorktreeRecord, laneContext: LandActLaneContext, pushOutcome: LanePushOutcome, context: ActContext
    ) async -> UnpublishedPinStep {
        let repository = laneContext.lane.repository
        guard let recordedCommit = recordedCommit(laneContext: laneContext, pushOutcome: pushOutcome, context: context)
        else {
            return .release(detail: nil)
        }
        let path = (held.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return .release(detail: nil) }

        let pin = UnpublishedHeadPin()
        let feature = laneContext.feature
        guard let branch = try? context.journal.resolvedFeatureBranch(feature: feature, repository: repository) else {
            if case .atRecordedCommit = await pin.headRelation(worktreePath: path, recordedCommit: recordedCommit) {
                return .release(detail: nil)
            }
            return .keepHeld(
                "the Worktree's HEAD in \(repository) is not the recorded commit \(recordedCommit.prefix(7)), and no "
                    + "Feature Branch is recorded to pin it under; the Worktree stays held"
            )
        }

        switch await pin.pinUnpublishedHead(worktreePath: path, recordedCommit: recordedCommit, branch: branch) {
        case .notNeeded:
            return .release(detail: nil)
        case .failed(let reason):
            return .keepHeld(
                "the Worktree's HEAD in \(repository) could not be pinned before release (\(reason)); the Worktree "
                    + "stays held and the next land firing retries"
            )
        case .pinned(let ref, let relation):
            guard let unpublished = UnpublishedHead(
                relation, repository: repository, recordedCommit: recordedCommit, noPushedBranch: !pushOutcome.pushed
            ) else {
                return .release(detail: nil)
            }
            await reportPinned(unpublished, pinRef: ref, laneContext: laneContext, context: context)
            return .release(detail: "pinned \(unpublished.head.prefix(7)) at \(ref)")
        }
    }

    /// The Pushed Tip this Cycle recorded (the push's own commit when none is recorded), or, with no completed work,
    /// the repository's recorded base commit.
    private func recordedCommit(
        laneContext: LandActLaneContext, pushOutcome: LanePushOutcome, context: ActContext
    ) -> String? {
        let repository = laneContext.lane.repository
        if pushOutcome.pushed {
            let recorded = try? context.journal.pushedTip(cycleID: laneContext.cycleID, repository: repository)
            return recorded ?? pushOutcome.commit
        }
        let bases = try? context.journal.featureBases(featureID: laneContext.feature.id)
        return bases?.first { $0.repository == repository }?.baseCommit
    }

    private func reportPinned(
        _ unpublished: UnpublishedHead, pinRef: String, laneContext: LandActLaneContext, context: ActContext
    ) async {
        _ = try? context.journal.append(
            .unpublishedCommitsPinned(cycleID: laneContext.cycleID, unpublished: unpublished, pinRef: pinRef),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        let placement = UnpublishedCommitsReport.Placement(
            cycleID: laneContext.cycleID, repository: unpublished.repository,
            featureIssueID: laneContext.feature.issueID, laneCards: laneContext.lane.cards
        )
        await UnpublishedCommitsReport.post(
            UnpublishedCommitsReport.atRelease(unpublished, pinRef: pinRef), kind: .release, at: placement,
            outbox: context.outbox
        )
    }
}
