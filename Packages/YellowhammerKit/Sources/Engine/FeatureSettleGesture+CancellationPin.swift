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
    ) throws -> WorktreeRecordedCommit? {
        let repository = held.repository
        if let pushedTip = try journal.pushedTip(cycleID: cycleID, repository: repository) {
            return WorktreeRecordedCommit(commit: pushedTip, noPushedBranch: false)
        }
        if let pushedCommit = held.pushedCommit {
            return WorktreeRecordedCommit(commit: pushedCommit, noPushedBranch: false)
        }
        let bases = try journal.featureBases(featureID: featureID)
        if let baseCommit = bases.first(where: { $0.repository == repository })?.baseCommit {
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
        let recorded: WorktreeRecordedCommit?
        let branch: FeatureBranch?
        do {
            recorded = try recordedCommit(
                held: worktree, cycleID: pinContext.cycleID, featureID: pinContext.feature.id, journal: journal
            )
            branch = try journal.resolvedFeatureBranch(feature: pinContext.feature, repository: repository)
        } catch {
            let comment = LandFailureComment.journalReadFailed(
                repository: repository, reason: String(describing: error), moment: .cancellation
            )
            try await failCancellation(comment, repository: repository, pinContext: pinContext)
        }
        let mainClonePath = pinContext.context.repositories?.repositoryPath(named: repository).map {
            WorktreeReconciler.expandedPath($0)
        }

        switch await UnpublishedPinDecision.evaluate(
            worktreePath: worktree.path, mainClonePath: mainClonePath, recordedCommit: recorded?.commit, branch: branch,
            reporting: (repository, recorded?.noPushedBranch ?? false)
        ) {
        case .notNeeded, .alreadyPinned:
            try await snapshotBeforeRelease(worktree: worktree, branch: branch, pinContext: pinContext)
        case .noFeatureBranch(let commit):
            throw CycleArchiveFault(
                reason: "the Worktree's HEAD in \(repository) is not the recorded commit \(commit.prefix(7)), and no "
                    + "Feature Branch is recorded to pin it under; the Worktree stays held"
            )
        case .failed(let reason):
            try await failPin(
                reason: reason, subject: .worktreeHead, repository: repository, recorded: recorded,
                pinContext: pinContext
            )
        case .pinned(let ref, let unpublished):
            await reportPinned(unpublished, ref: ref, pinContext: pinContext)
            try await snapshotBeforeRelease(worktree: worktree, branch: branch, pinContext: pinContext)
        case .gone(let step):
            try await handleHeldWorktree(
                step: step, isGone: true, worktree: worktree,
                held: HeldPinFacts(recordedCommit: recorded?.commit, branch: branch, path: worktree.path),
                pinContext: pinContext
            )
        case .notGitWorktree(let step):
            try await handleHeldWorktree(
                step: step, isGone: false, worktree: worktree,
                held: HeldPinFacts(recordedCommit: recorded?.commit, branch: branch, path: worktree.path),
                pinContext: pinContext
            )
        }
    }

    private func reportPinned(
        _ unpublished: UnpublishedHead, ref: String, pinContext: CancellationPinContext
    ) async {
        let repository = unpublished.repository
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

    /// Saves the present git Worktree's uncommitted changes before release (OQ196 item 1). A saved snapshot is
    /// recorded and reported; one that cannot be saved defers the whole cancellation, as a failed pin does.
    private func snapshotBeforeRelease(
        worktree: WorktreeRecord, branch: FeatureBranch?, pinContext: CancellationPinContext
    ) async throws {
        let repository = worktree.repository
        switch await WorktreeSnapshotDecision.evaluate(
            worktreePath: worktree.path, repository: repository, branch: branch, moment: .cancellation
        ) {
        case .nothingToSave:
            return
        case .keepHeld(let comment):
            try await failCancellation(comment, repository: repository, pinContext: pinContext)
        case .saved(let saved):
            let context = pinContext.context
            _ = try? context.journal.append(
                .uncommittedChangesSnapshotted(cycleID: pinContext.cycleID, snapshot: saved),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            let placement = LandCommentPlacement(
                cycleID: pinContext.cycleID, repository: repository, featureIssueID: pinContext.feature.issueID,
                laneCards: pinContext.cards.filter { $0.repository == repository }
            )
            await UnpublishedCommitsReport.postSnapshot(saved, at: placement, outbox: context.outbox)
        }
    }

    /// Posts `comment` on the Feature Card and the repository's Cards, then defers the cancellation with the
    /// comment's own text as the fault's reason. The Outbox row is persisted although the Act ends incomplete.
    private func failCancellation(
        _ comment: (body: String, keySuffix: String), repository: String, pinContext: CancellationPinContext
    ) async throws -> Never {
        let placement = LandCommentPlacement(
            cycleID: pinContext.cycleID, repository: repository, featureIssueID: pinContext.feature.issueID,
            laneCards: pinContext.cards.filter { $0.repository == repository }
        )
        await placement.post(comment.body, keySuffix: comment.keySuffix, outbox: pinContext.context.outbox)
        throw CycleArchiveFault(reason: comment.body)
    }

    private func failPin(
        reason: String, subject: PinSubject, repository: String, recorded: WorktreeRecordedCommit?,
        pinContext: CancellationPinContext
    ) async throws -> Never {
        let comment = LandFailureComment.pinFailed(
            subject: subject, repository: repository, reason: reason, recordedCommit: recorded?.commit,
            moment: .cancellation
        )
        try await failCancellation(comment, repository: repository, pinContext: pinContext)
    }

    private func handleHeldWorktree(
        step: UnpublishedPinDecision.MainCloneBranchStep, isGone: Bool, worktree: WorktreeRecord,
        held: HeldPinFacts, pinContext: CancellationPinContext
    ) async throws {
        let verdict = HeldWorktreeVerdict.evaluate(
            step: step, isGone: isGone,
            held: held,
            repository: worktree.repository, moment: .cancellation
        )
        if let report = verdict.report {
            await reportPinned(report.unpublished, ref: report.ref, pinContext: pinContext)
        }
        if let comment = verdict.failure {
            try await failCancellation(comment, repository: worktree.repository, pinContext: pinContext)
        }
    }
}
