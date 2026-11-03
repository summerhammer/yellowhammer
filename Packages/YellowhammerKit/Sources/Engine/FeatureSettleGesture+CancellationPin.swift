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

    /// Pins the HEAD (or the main clone's Feature Branch if the Worktree directory is gone or not a git work tree)
    /// of each held Worktree whose commit is not the recorded commit before release (OQ194 item 3, Pin Failure
    /// item 2). Defers the abandon by throwing ``CycleArchiveFault`` when a pin cannot be written, a moved HEAD
    /// has no Feature Branch to pin it under, or the directory is not a git work tree so uncommitted changes
    /// cannot be saved (OQ196 item 2), keeping every Worktree held.
    func pinWorktrees(
        feature: FeatureRecord, cycleID: Int64, cards: [CardRecord], context: ActContext
    ) async throws {
        let journal = context.journal
        let held = try journal.worktrees(featureID: feature.id).filter(\.isHeld)
        guard !held.isEmpty else { return }

        let pinContext = CancellationPinContext(
            feature: feature, cycleID: cycleID, cards: cards, context: context
        )
        for worktree in held {
            try await pinHeldWorktree(worktree, pinContext: pinContext)
        }
    }

    private struct CancellationPinContext {
        let feature: FeatureRecord
        let cycleID: Int64
        let cards: [CardRecord]
        let context: ActContext
    }

    private func pinHeldWorktree(
        _ worktree: WorktreeRecord, pinContext: CancellationPinContext
    ) async throws {
        let journal = pinContext.context.journal
        let repository = worktree.repository
        let recorded = recordedCommit(
            held: worktree, cycleID: pinContext.cycleID, featureID: pinContext.feature.id, journal: journal
        )
        let branch = try? journal.resolvedFeatureBranch(feature: pinContext.feature, repository: repository)
        let mainClonePath = pinContext.context.repositories?.repositoryPath(named: repository).map {
            WorktreeReconciler.expandedPath($0)
        }

        switch await UnpublishedPinDecision.evaluate(
            worktreePath: worktree.path, mainClonePath: mainClonePath, recordedCommit: recorded?.commit, branch: branch
        ) {
        case .notNeeded, .alreadyPinned:
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
            if let recorded {
                await reportPinned(
                    relation: relation, ref: ref, repository: repository, recorded: recorded, pinContext: pinContext
                )
            }

        case .gone(let step):
            try await handleGoneWorktree(
                step: step, repository: repository, recorded: recorded, pinContext: pinContext
            )

        case .notGitWorktree(let step):
            try await handleNotGitWorktree(
                step: step, repository: repository, recorded: recorded, pinContext: pinContext
            )
        }
    }

    private func reportPinned(
        relation: WorktreeHeadRelation, ref: String, repository: String, recorded: WorktreeRecordedCommit,
        pinContext: CancellationPinContext
    ) async {
        guard let unpublished = UnpublishedHead(
            relation, repository: repository, recordedCommit: recorded.commit,
            noPushedBranch: recorded.noPushedBranch
        ) else { return }
        let context = pinContext.context
        _ = try? context.journal.append(
            .unpublishedCommitsPinnedAtCancellation(cycleID: pinContext.cycleID, unpublished: unpublished, pinRef: ref),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        let laneCards = pinContext.cards.filter { $0.repository == repository }
        let placement = LandCommentPlacement(
            cycleID: pinContext.cycleID, repository: repository,
            featureIssueID: pinContext.feature.issueID, laneCards: laneCards
        )
        await UnpublishedCommitsReport.post(
            UnpublishedCommitsReport.atCancellation(unpublished, pinRef: ref),
            kind: .cancellation,
            at: placement,
            outbox: context.outbox
        )
    }

    private func handleGoneWorktree(
        step: UnpublishedPinDecision.MainCloneBranchStep, repository: String, recorded: WorktreeRecordedCommit?,
        pinContext: CancellationPinContext
    ) async throws {
        switch step {
        case .notNeeded, .absent, .alreadyPinned, .noFeatureBranch:
            return
        case .failed(let reason):
            throw CycleArchiveFault(
                reason: "the Worktree in \(repository) could not be pinned before release (\(reason)); "
                    + "the Worktree stays held and the next author firing tries again"
            )
        case .pinned(let ref, let relation):
            if let recorded {
                await reportPinned(
                    relation: relation, ref: ref, repository: repository, recorded: recorded, pinContext: pinContext
                )
            }
        }
    }

    private func handleNotGitWorktree(
        step: UnpublishedPinDecision.MainCloneBranchStep, repository: String, recorded: WorktreeRecordedCommit?,
        pinContext: CancellationPinContext
    ) async throws {
        let baseFault = "the Worktree directory in \(repository) is not a git work tree, so its uncommitted "
            + "changes cannot be saved"
        switch step {
        case .notNeeded, .absent, .noFeatureBranch:
            throw CycleArchiveFault(
                reason: "\(baseFault); the Worktree stays held and the next author firing tries again"
            )
        case .alreadyPinned(let ref):
            throw CycleArchiveFault(
                reason: "\(baseFault); already pinned at \(ref); the Worktree stays held and the next author "
                    + "firing tries again"
            )
        case .failed(let reason):
            throw CycleArchiveFault(
                reason: "the Worktree in \(repository) could not be pinned before release (\(reason)); "
                    + "the Worktree stays held and the next author firing tries again"
            )
        case .pinned(let ref, let relation):
            if let recorded {
                await reportPinned(
                    relation: relation, ref: ref, repository: repository, recorded: recorded, pinContext: pinContext
                )
            }
            throw CycleArchiveFault(
                reason: "\(baseFault); pinned at \(ref); the Worktree stays held and the next author "
                    + "firing tries again"
            )
        }
    }
}
