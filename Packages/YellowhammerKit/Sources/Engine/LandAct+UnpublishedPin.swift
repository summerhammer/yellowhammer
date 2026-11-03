import Domain
import Foundation
import Journal
import Repositories

// The unpublished-commits pin (spec: landing/open-one-pull-request-per-repository, `#unpublished-commits-pin`;
// OQ191 items 1, 5, 6 and 9; Pin Failure item 2; OQ196 item 2): before the land Act releases a held Worktree whose
// HEAD is not its repository's recorded commit — descendant or not — it pins that HEAD at
// `refs/yellowhammer/unpublished/<branch>` in the main clone, outside `refs/heads/`, which Orca ADE does not delete.
// The pin is never pushed or published and does not block the Cycle from landing; it is reported as not published,
// naming the pin and the commits. A pin that cannot be written keeps the Worktree held: the release step fails and
// the next land firing retries, so no commit is lost to Orca ADE's removal (the lead's decision; not ruled). When
// a Worktree directory is gone or is not a git work tree, the Feature Branch is read in the main clone before
// release; if it resolves and is not the recorded commit, it is pinned under `refs/yellowhammer/unpublished/<branch>`.
// A gone directory is released after the branch pin, while a non-git directory stays held because its uncommitted
// changes cannot be saved (OQ196 item 2). A pin an earlier firing already wrote at the same commit is neither
// reported nor posted again. A pin or non-git directory that keeps the Worktree held posts a board comment naming the
// cause and a route out (``LandFailureComment``), and the release step's detail is that same text. Once the pin
// decision allows a present git Worktree to be released, its uncommitted changes are saved as a snapshot under
// `refs/yellowhammer/snapshot/<branch>` (``UncommittedSnapshot``, OQ196 item 1) and reported as not published; a
// snapshot that cannot be written keeps the Worktree held and the next land firing tries again.

/// What evaluating and attempting to pin a held Worktree's HEAD or main-clone Feature Branch produced.
enum UnpublishedPinDecision: Sendable {
    case notNeeded
    case alreadyPinned(ref: String)
    case noFeatureBranch(recordedCommit: String)
    case failed(reason: String)
    case pinned(ref: String, relation: WorktreeHeadRelation)
    case gone(MainCloneBranchStep)
    case notGitWorktree(MainCloneBranchStep)

    enum MainCloneBranchStep: Sendable {
        case pinned(ref: String, relation: WorktreeHeadRelation)
        case alreadyPinned(ref: String)
        case notNeeded
        case absent
        case failed(reason: String)
        case noFeatureBranch
    }

    static func evaluate(
        worktreePath: String, mainClonePath: String?, recordedCommit: String?, branch: FeatureBranch?,
        pin: UnpublishedHeadPin = UnpublishedHeadPin()
    ) async -> UnpublishedPinDecision {
        let path = (worktreePath as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: path)
        let isGitWorktree = exists && FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )

        if !exists || !isGitWorktree {
            let branchStep = await evaluateMainClone(
                mainClonePath: mainClonePath, recordedCommit: recordedCommit, branch: branch, pin: pin
            )
            return exists ? .notGitWorktree(branchStep) : .gone(branchStep)
        }

        // Present, valid git work tree:
        // Lead decision: No recorded commit means nothing to compare, so do not pin.
        guard let recordedCommit else { return .notNeeded }

        // Lead decision: No Feature Branch recorded gives nil -> pin if HEAD moved, or keep held.
        guard let branch else {
            if case .atRecordedCommit = await pin.headRelation(worktreePath: path, recordedCommit: recordedCommit) {
                return .notNeeded
            }
            return .noFeatureBranch(recordedCommit: recordedCommit)
        }
        switch await pin.pinUnpublishedHead(worktreePath: path, recordedCommit: recordedCommit, branch: branch) {
        case .notNeeded:
            return .notNeeded
        case .alreadyPinned(let ref):
            return .alreadyPinned(ref: ref)
        case .failed(let reason):
            return .failed(reason: reason)
        case .pinned(let ref, let relation):
            return .pinned(ref: ref, relation: relation)
        }
    }

    private static func evaluateMainClone(
        mainClonePath: String?, recordedCommit: String?, branch: FeatureBranch?, pin: UnpublishedHeadPin
    ) async -> MainCloneBranchStep {
        // Lead decision: No Feature Branch recorded gives nil -> nothing to read.
        guard let branch else { return .noFeatureBranch }

        // Lead decision: No recorded commit means nothing to compare, so nothing is pinned; a gone directory
        // releases as before, and a non-git one still stays held (its caller's rule).
        guard let recordedCommit else { return .notNeeded }

        // Lead decision, by analogy with Pin Failure item 1: a main clone that cannot be read (nil repositories,
        // no configured path, or git failing) keeps the Worktree held.
        guard let mainClonePath else {
            return .failed(reason: "no repository path is configured for the repository")
        }

        switch await pin.pinFeatureBranch(
            repositoryPath: mainClonePath, recordedCommit: recordedCommit, branch: branch
        ) {
        case .pinned(let ref, let relation):
            return .pinned(ref: ref, relation: relation)
        case .alreadyPinned(let ref):
            return .alreadyPinned(ref: ref)
        case .notNeeded:
            return .notNeeded
        case .absent:
            return .absent
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}

/// What the pin before release decided.
enum UnpublishedPinStep {
    /// The Worktree may be released; `detail` names the pin when one was written.
    case release(detail: String?)
    /// The Worktree stays held: the release step fails with this detail.
    case keepHeld(String)
}

extension LandAct {
    /// Pins the held Worktree's HEAD (or the main clone's Feature Branch if the directory is gone or not a git work
    /// tree) when it is not the recorded commit, and reports it. A gone directory releases after pinning (or if
    /// unneeded/absent), while a non-git directory stays held because uncommitted changes cannot be saved (OQ196).
    func pinUnpublishedHead(
        held: WorktreeRecord, laneContext: LandActLaneContext, pushOutcome: LanePushOutcome, context: ActContext
    ) async -> UnpublishedPinStep {
        let repository = laneContext.lane.repository
        let recordedCommit = recordedCommit(laneContext: laneContext, pushOutcome: pushOutcome, context: context)
        let branch = try? context.journal.resolvedFeatureBranch(feature: laneContext.feature, repository: repository)
        let mainClonePath = context.repositories?.repositoryPath(named: repository).map {
            WorktreeReconciler.expandedPath($0)
        }

        switch await UnpublishedPinDecision.evaluate(
            worktreePath: held.path, mainClonePath: mainClonePath, recordedCommit: recordedCommit, branch: branch
        ) {
        case .notNeeded:
            return await snapshotBeforeRelease(
                pinDetail: nil, held: held, branch: branch, laneContext: laneContext, context: context
            )
        case .noFeatureBranch(let commit):
            return .keepHeld(
                "the Worktree's HEAD in \(repository) is not the recorded commit \(commit.prefix(7)), and no "
                    + "Feature Branch is recorded to pin it under; the Worktree stays held"
            )
        case .alreadyPinned(let ref):
            return await snapshotBeforeRelease(
                pinDetail: "already pinned at \(ref)", held: held, branch: branch, laneContext: laneContext,
                context: context
            )
        case .failed(let reason):
            let comment = LandFailureComment.pinFailed(
                subject: .worktreeHead, repository: repository, reason: reason, recordedCommit: recordedCommit,
                moment: .land
            )
            return await keepHeldWithComment(comment, laneContext: laneContext, context: context)
        case .pinned(let ref, let relation):
            let pinDetail = await reportWorktreePin(
                pin: (ref, relation), recordedCommit: recordedCommit, pushOutcome: pushOutcome,
                laneContext: laneContext, context: context
            )
            return await snapshotBeforeRelease(
                pinDetail: pinDetail, held: held, branch: branch, laneContext: laneContext, context: context
            )

        case .gone(let step):
            return await handleGoneWorktree(
                step: step, held: HeldPinFacts(recordedCommit: recordedCommit, branch: branch, path: held.path),
                pushOutcome: pushOutcome, laneContext: laneContext, context: context
            )

        case .notGitWorktree(let step):
            return await handleNotGitWorktree(
                step: step, held: HeldPinFacts(recordedCommit: recordedCommit, branch: branch, path: held.path),
                pushOutcome: pushOutcome, laneContext: laneContext, context: context
            )
        }
    }

    /// Reports a pinned Worktree HEAD; the release step's detail naming the pin, nil when nothing differs to report.
    private func reportWorktreePin(
        pin: (ref: String, relation: WorktreeHeadRelation), recordedCommit: String?, pushOutcome: LanePushOutcome,
        laneContext: LandActLaneContext, context: ActContext
    ) async -> String? {
        guard let recordedCommit,
              let unpublished = UnpublishedHead(
                  pin.relation, repository: laneContext.lane.repository, recordedCommit: recordedCommit,
                  noPushedBranch: !pushOutcome.pushed
              ) else { return nil }
        let ref = pin.ref
        await reportPinned(unpublished, pinRef: ref, laneContext: laneContext, context: context)
        return "pinned \(unpublished.head.prefix(7)) at \(ref)"
    }

    /// Saves the present git Worktree's uncommitted changes before release. A saved snapshot is recorded and reported
    /// and named in the release step's detail after the pin's; one that cannot be saved keeps the Worktree held.
    private func snapshotBeforeRelease(
        pinDetail: String?, held: WorktreeRecord, branch: FeatureBranch?, laneContext: LandActLaneContext,
        context: ActContext
    ) async -> UnpublishedPinStep {
        let repository = laneContext.lane.repository
        switch await WorktreeSnapshotDecision.evaluate(
            worktreePath: held.path, repository: repository, branch: branch, moment: .land
        ) {
        case .nothingToSave:
            return .release(detail: pinDetail)
        case .keepHeld(let comment):
            return await keepHeldWithComment(comment, laneContext: laneContext, context: context)
        case .saved(let saved):
            _ = try? context.journal.append(
                .uncommittedChangesSnapshotted(cycleID: laneContext.cycleID, snapshot: saved),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            let placement = LandCommentPlacement(
                cycleID: laneContext.cycleID, repository: repository,
                featureIssueID: laneContext.feature.issueID, laneCards: laneContext.lane.cards
            )
            await UnpublishedCommitsReport.postSnapshot(saved, at: placement, outbox: context.outbox)
            return .release(detail: [pinDetail, "snapshot at \(saved.ref)"].compactMap { $0 }.joined(separator: "; "))
        }
    }

    /// Posts `comment` on the Feature Card and the Done lane Cards, and keeps the Worktree held with the comment's
    /// own text as the release step's detail, so the Journal and the board read one text.
    private func keepHeldWithComment(
        _ comment: (body: String, keySuffix: String), laneContext: LandActLaneContext, context: ActContext
    ) async -> UnpublishedPinStep {
        let placement = LandCommentPlacement(
            cycleID: laneContext.cycleID, repository: laneContext.lane.repository,
            featureIssueID: laneContext.feature.issueID, laneCards: laneContext.lane.cards
        )
        await placement.post(comment.body, keySuffix: comment.keySuffix, outbox: context.outbox)
        return .keepHeld(comment.body)
    }

    private func branchPinFailed(
        reason: String, branch: FeatureBranch?, recordedCommit: String?, laneContext: LandActLaneContext,
        context: ActContext
    ) async -> UnpublishedPinStep {
        let comment = LandFailureComment.pinFailed(
            subject: branch.map(PinSubject.featureBranch) ?? .worktreeHead,
            repository: laneContext.lane.repository, reason: reason, recordedCommit: recordedCommit, moment: .land
        )
        return await keepHeldWithComment(comment, laneContext: laneContext, context: context)
    }

    /// What the gone and non-git handlers know of the held Worktree.
    struct HeldPinFacts {
        let recordedCommit: String?
        let branch: FeatureBranch?
        let path: String
    }

    private func handleGoneWorktree(
        step: UnpublishedPinDecision.MainCloneBranchStep, held: HeldPinFacts,
        pushOutcome: LanePushOutcome, laneContext: LandActLaneContext, context: ActContext
    ) async -> UnpublishedPinStep {
        let (recordedCommit, branch) = (held.recordedCommit, held.branch)
        let repository = laneContext.lane.repository
        switch step {
        case .notNeeded, .noFeatureBranch:
            return .release(detail: nil)
        case .absent:
            // `.absent` is only read for a recorded Feature Branch; the name is left out if none is.
            let name = branch.map { " `\($0.rawValue)`" } ?? ""
            return .release(
                detail: "nothing was pinned: the Feature Branch\(name) does not resolve in the main clone"
            )
        case .alreadyPinned(let ref):
            return .release(detail: "already pinned at \(ref)")
        case .failed(let reason):
            return await branchPinFailed(
                reason: reason, branch: branch, recordedCommit: recordedCommit, laneContext: laneContext,
                context: context
            )
        case .pinned(let ref, let relation):
            guard let recordedCommit,
                  let unpublished = UnpublishedHead(
                      relation, repository: repository, recordedCommit: recordedCommit,
                      noPushedBranch: !pushOutcome.pushed
                  ) else {
                return .release(detail: nil)
            }
            await reportPinned(unpublished, pinRef: ref, laneContext: laneContext, context: context)
            return .release(detail: "pinned \(unpublished.head.prefix(7)) at \(ref)")
        }
    }

    private func handleNotGitWorktree(
        step: UnpublishedPinDecision.MainCloneBranchStep, held: HeldPinFacts,
        pushOutcome: LanePushOutcome, laneContext: LandActLaneContext, context: ActContext
    ) async -> UnpublishedPinStep {
        let (recordedCommit, branch, worktreePath) = (held.recordedCommit, held.branch, held.path)
        let repository = laneContext.lane.repository
        var pinRef: String?
        switch step {
        case .notNeeded, .absent, .noFeatureBranch:
            break
        case .alreadyPinned(let ref):
            pinRef = ref
        case .failed(let reason):
            return await branchPinFailed(
                reason: reason, branch: branch, recordedCommit: recordedCommit, laneContext: laneContext,
                context: context
            )
        case .pinned(let ref, let relation):
            if let recordedCommit,
               let unpublished = UnpublishedHead(
                   relation, repository: repository, recordedCommit: recordedCommit,
                   noPushedBranch: !pushOutcome.pushed
               ) {
                await reportPinned(unpublished, pinRef: ref, laneContext: laneContext, context: context)
            }
            pinRef = ref
        }
        let comment = LandFailureComment.notGitWorktree(
            repository: repository, path: worktreePath, pinRef: pinRef, moment: .land
        )
        return await keepHeldWithComment(comment, laneContext: laneContext, context: context)
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
        let placement = LandCommentPlacement(
            cycleID: laneContext.cycleID, repository: unpublished.repository,
            featureIssueID: laneContext.feature.issueID, laneCards: laneContext.lane.cards
        )
        await UnpublishedCommitsReport.post(
            UnpublishedCommitsReport.atRelease(unpublished, pinRef: pinRef), kind: .release, at: placement,
            outbox: context.outbox
        )
    }
}
