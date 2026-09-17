import Domain
import Journal
import Repositories

// Ghost-Worktree handling, split out of WorktreeReconciler.swift to keep it under the file length limit.

extension WorktreeReconciler {
    /// Handles a held Worktree whose recorded path no longer exists (loop-state/reconcile-worktrees-at-act-start):
    /// Orca ADE's stale record of it is purged best-effort (a `.worktreeNotFound` refusal, or any other
    /// error, is tolerated — the Journal record is what matters here), the Journal marks the Worktree
    /// lost, and every in-progress Card of this repository, in the in-flight Cycle, returns to Todo so a
    /// later Act redispatches it into a fresh Worktree rather than assuming stale progress.
    func purgeGhost(_ record: WorktreeRecord) async throws -> WorktreeReconciliationOutcome {
        _ = try? await workspace.removeWorktree(id: WorktreeID(rawValue: record.worktreeID), force: true)

        let lostRecord = try journal.recordWorktreeLost(id: record.id, runID: runID)
        try journal.append(
            .worktreeLost(
                featureID: record.featureID, repository: record.repository,
                worktreeID: record.worktreeID, path: record.path
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
