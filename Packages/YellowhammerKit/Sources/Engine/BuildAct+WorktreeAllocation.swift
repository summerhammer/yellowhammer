import Domain
import Journal

// The build Act's per-lane Worktree allocation, split out of BuildAct.swift to keep it under the file
// length limit.

extension BuildAct {
    /// Allocates this lane's Repo's Worktree (graph-execution/allocate-a-worktree-per-graph-and-repo)
    /// before its first Card, when the lane has Cards to run and a Workspace is bound. Returns a
    /// description of the failure when allocation cannot proceed; nil otherwise. A branch-name collision
    /// is not a lane failure: it is thrown as
    /// ``BuildActError/worktreeNameCollision(repository:requested:reported:)`` and halts the Act. Skips
    /// allocation entirely — never returning a failure — when the lane has no runnable Cards or no
    /// Workspace is bound, so a fake-runner test with no Workspace keeps behaving exactly as before.
    func allocateWorktree(
        runnable: [CardRecord], lane: RepoLane, context: BuildActContext, actContext: ActContext
    ) async throws -> String? {
        guard !runnable.isEmpty, let workspace = actContext.workspace else { return nil }

        guard let worktreeName = context.feature.worktreeName else {
            return BuildActError.worktreeNameUnrecorded(featureID: context.feature.id).description
        }

        // Never dispatch over a lane whose reconciliation did not settle, before the held-Worktree reuse below.
        if let reason = context.reconciliation.undispatchableReason(for: lane.repository) { return reason }

        // A Worktree already held for (Feature, repository) is reused with no Orca ADE call
        // (``WorktreeAllocator/allocate(featureID:worktreeName:repos:)``), so no configured ``Repo`` is
        // needed to resolve it — only a fresh allocation needs the repository's path.
        do {
            if try actContext.journal.heldWorktree(featureID: context.feature.id, repository: lane.repository) != nil {
                return nil
            }
        } catch {
            return String(describing: error)
        }

        guard let repo = actContext.repositories?.workingRepo(named: lane.repository) else {
            return "no configured repository named '\(lane.repository)' for Worktree allocation"
        }

        let allocator = WorktreeAllocator(workspace: workspace, journal: actContext.journal, runID: actContext.runID)
        do {
            _ = try await allocator.allocate(featureID: context.feature.id, worktreeName: worktreeName, repos: [repo])
            return nil
        } catch let WorktreeAllocationError.nameCollision(repository, requested, reported, recorded) {
            throw BuildActError.worktreeNameCollision(
                repository: repository, requested: recorded ?? requested, reported: reported
            )
        } catch {
            return String(describing: error)
        }
    }
}
