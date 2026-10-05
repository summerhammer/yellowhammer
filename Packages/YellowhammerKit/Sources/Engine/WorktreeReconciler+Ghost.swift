import Domain
import Journal
import Repositories

// Ghost-Worktree handling, split out of WorktreeReconciler.swift to keep it under the file length limit.

extension WorktreeReconciler {
    /// Handles a held Worktree whose recorded path no longer exists (loop-state/reconcile-worktrees-at-act-start).
    ///
    /// The Feature Branch is pinned FIRST (``pinFeatureBranch(_:branch:)``, OQ123): Orca ADE deletes a
    /// removed Worktree's checked-out branch, and before the land Act that branch is the only copy of the
    /// Feature's Done Cards' commits in this repository. If the pin cannot be written nothing else
    /// happens — no `rm`, no lost mark, no Card transitions — the failure is recorded, the Worktree stays
    /// held, and the outcome is `.ghostKept`.
    ///
    /// Then Orca ADE's stale record of the Worktree is purged best-effort (a `.worktreeNotFound` refusal,
    /// or any other error, is tolerated — the Journal record is what matters here). When the purge
    /// succeeded and a pin was written, this waits (advisory: a timeout does not fail the purge) for Orca
    /// ADE's asynchronous branch deletion to finish, so that re-allocation in this same Act does not find
    /// the branch still there and get a silently renamed Worktree; a branch that survives anyway is caught
    /// by the allocator's collision path, whose Operator remedy is non-destructive because the pin holds
    /// the commits. Finally the Journal marks the Worktree lost and every in-progress Card of this
    /// repository, in the in-flight Cycle, returns to Todo so a later Act redispatches it into a fresh
    /// Worktree rather than assuming stale progress.
    func purgeGhost(_ record: WorktreeRecord, branch: FeatureBranch) async throws -> WorktreeReconciliationOutcome {
        var pinnedCommit: String?
        switch try await pinFeatureBranch(record, branch: branch) {
        case .pinned(let commit):
            pinnedCommit = commit
        case .nothingToPin:
            break
        case .held(let reason):
            try recordFailure(record, reason: reason)
            return .ghostKept(record, reason: reason)
        }

        var removed = false
        do {
            try await workspace.removeWorktree(id: WorktreeID(rawValue: record.worktreeID), force: true)
            removed = true
        } catch {
            // Tolerated: the Journal record is what matters here.
        }
        if removed, pinnedCommit != nil, let configured = repositories?.repositoryPath(named: record.repository) {
            _ = await recoveryPin.waitUntilBranchGone(
                branch, repositoryPath: Self.expandedPath(configured),
                timeout: branchDeletionTimeout, interval: branchDeletionPollInterval
            )
        }

        let lostRecord = try journal.recordWorktreeLost(id: record.id, runID: runID)
        try journal.append(
            .worktreeLost(
                featureID: record.featureID, repository: record.repository,
                worktreeID: record.worktreeID, path: record.path, pinnedCommit: pinnedCommit
            ),
            act: act, runID: runID, nightID: nightID
        )

        if let cycleID = try journal.inFlightCycleID() {
            let strandedCards = try journal.cards().filter {
                $0.cycleID == cycleID && $0.repository == record.repository && $0.state == .inProgress
            }
            for card in strandedCards {
                try journal.transitionCard(cardID: card.id, to: .todo, runID: runID, act: act, nightID: nightID)
            }
        }

        return .lost(lostRecord)
    }
}
