import Domain
import Foundation
import Journal
import Repositories

extension FeatureSettleGesture {
    struct WorktreeRecordedCommit {
        let commit: String
        let noPushedBranch: Bool
    }

    func recordedCommit(
        held: WorktreeRecord, cycleID: Int64, featureID: Int64, journal: JournalStore
    ) -> WorktreeRecordedCommit? {
        let repository = held.repository
        if let pushedTip = try? journal.pushedTip(cycleID: cycleID, repository: repository) {
            return WorktreeRecordedCommit(commit: pushedTip, noPushedBranch: false)
        }
        if let pushedCommit = held.pushedCommit {
            return WorktreeRecordedCommit(commit: pushedCommit, noPushedBranch: false)
        }
        if let bases = try? journal.featureBases(featureID: featureID),
           let baseCommit = bases.first(where: { $0.repository == repository })?.baseCommit {
            return WorktreeRecordedCommit(commit: baseCommit, noPushedBranch: true)
        }
        return nil
    }

    /// Pins the HEAD of each held Worktree whose HEAD is not the recorded commit before release
    /// (OQ194 item 3). Defers the abandon by throwing ``CycleArchiveFault`` when a pin cannot be written
    /// or a moved HEAD has no Feature Branch to pin it under, keeping every Worktree held.
    func pinWorktrees(
        feature: FeatureRecord, cycleID: Int64, cards: [CardRecord], context: ActContext
    ) async throws {
        let journal = context.journal
        let held = try journal.worktrees(featureID: feature.id).filter(\.isHeld)
        guard !held.isEmpty else { return }

        for worktree in held {
            try await pinHeldWorktree(
                worktree, feature: feature, cycleID: cycleID, cards: cards, context: context
            )
        }
    }

    private func pinHeldWorktree(
        _ worktree: WorktreeRecord, feature: FeatureRecord, cycleID: Int64, cards: [CardRecord],
        context: ActContext
    ) async throws {
        let journal = context.journal
        let repository = worktree.repository
        guard let recorded = recordedCommit(
            held: worktree, cycleID: cycleID, featureID: feature.id, journal: journal
        ) else {
            return
        }
        let branch = try? journal.resolvedFeatureBranch(feature: feature, repository: repository)
        switch await UnpublishedPinDecision.evaluate(
            worktreePath: worktree.path, recordedCommit: recorded.commit, branch: branch
        ) {
        case .missingWorktree, .notGitWorktree, .notNeeded, .alreadyPinned:
            return
        case .noFeatureBranch(let commit):
            throw CycleArchiveFault(
                reason: "the Worktree's HEAD in \(repository) is not the recorded commit \(commit.prefix(7)), and no "
                    + "Feature Branch is recorded to pin it under; the Worktree stays held"
            )
        case .failed(let reason):
            throw CycleArchiveFault(
                reason: "the Worktree's HEAD in \(repository) could not be pinned before release (\(reason)); "
                    + "the Worktree stays held and the next author firing retries"
            )
        case .pinned(let ref, let relation):
            guard let unpublished = UnpublishedHead(
                relation, repository: repository, recordedCommit: recorded.commit,
                noPushedBranch: recorded.noPushedBranch
            ) else {
                return
            }
            _ = try? context.journal.append(
                .unpublishedCommitsPinnedAtCancellation(cycleID: cycleID, unpublished: unpublished, pinRef: ref),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            let laneCards = cards.filter { $0.repository == repository }
            let placement = LandCommentPlacement(
                cycleID: cycleID, repository: repository, featureIssueID: feature.issueID, laneCards: laneCards
            )
            await UnpublishedCommitsReport.post(
                UnpublishedCommitsReport.atCancellation(unpublished, pinRef: ref),
                kind: .cancellation,
                at: placement,
                outbox: context.outbox
            )
        }
    }
}
