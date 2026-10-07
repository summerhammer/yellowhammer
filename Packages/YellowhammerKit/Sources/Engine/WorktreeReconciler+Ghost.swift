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
    ///
    /// A Feature Branch that is already gone (the Operator removed the Worktree in Orca ADE) is not a reason
    /// to hold the lane (OQ133): the pin falls back to the lane's `last_known_good_commit`, and re-allocation
    /// recovers from it like from a branch tip. Only when that object is gone too is the loss recorded on the
    /// `worktreeLost` event — the lost tip and the Done Cards of the lane — for the Night Summary to name.
    /// Nothing is named for work already pushed: it survives on the remote.
    func purgeGhost(_ record: WorktreeRecord, branch: FeatureBranch) async throws -> WorktreeReconciliationOutcome {
        var pinnedCommit: String?
        var waitsForBranchDeletion = false
        var unrecovered = false
        var lostCommit: String?
        switch try await pinFeatureBranch(record, branch: branch) {
        case .pinned(let commit):
            pinnedCommit = commit
            waitsForBranchDeletion = true
        case .pinnedLastKnownGood(let commit):
            // The branch was already gone, so Orca ADE has no deletion left to finish: nothing to wait for.
            pinnedCommit = commit
        case .nothingToPin(let lost):
            unrecovered = record.pushedCommit == nil
            lostCommit = unrecovered ? lost : nil
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
        if removed, waitsForBranchDeletion, let configured = repositories?.repositoryPath(named: record.repository) {
            _ = await recoveryPin.waitUntilBranchGone(
                branch, repositoryPath: Self.expandedPath(configured),
                timeout: branchDeletionTimeout, interval: branchDeletionPollInterval
            )
        }

        let lostRecord = try journal.recordWorktreeLost(id: record.id, runID: runID)
        let cycleCards: [CardRecord]
        if let cycleID = try journal.inFlightCycleID() {
            cycleCards = try journal.cards().filter { $0.cycleID == cycleID && $0.repository == record.repository }
        } else {
            cycleCards = []
        }
        let lostDoneCardIDs = unrecovered ? cycleCards.filter { $0.state == .done }.map(\.id) : []
        try journal.append(
            .worktreeLost(
                featureID: record.featureID, repository: record.repository,
                worktreeID: record.worktreeID, path: record.path, pinnedCommit: pinnedCommit,
                lostCommit: lostCommit, lostDoneCardIDs: lostDoneCardIDs
            ),
            act: act, runID: runID, nightID: nightID
        )

        for card in cycleCards where card.state == .inProgress {
            try journal.transitionCard(cardID: card.id, to: .todo, runID: runID, act: act, nightID: nightID)
        }

        return .lost(lostRecord)
    }
}
