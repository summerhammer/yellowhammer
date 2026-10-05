import Config
import Domain
import Engine
import Foundation
import Journal
import Repositories

// Steps 7-9 of removal: comment on the in-flight Feature Issue, resolve the mode to run the WIP commit
// under, and WIP-commit/push/remove every held Worktree.

/// What step 9 (``ProjectRemoval/removeWorktrees(journal:project:mode:push:)``) did: the Worktree ids it
/// released, and any step failure it hit along the way — a Worktree it could not resolve or remove is
/// left held and named here, never silently dropped.
struct WorktreeRemovalResult {
    let releasedWorktreeIDs: [Int64]
    let failures: [String]
}

/// Everything one held Worktree's disposition needs, bundled so the functions that thread it through
/// stay under SwiftLint's parameter-count limit.
private struct WorktreeRemovalContext {
    let journal: JournalStore
    let project: ProjectConfiguration
    let mode: NightMode
    let push: @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome
    let committer: WorktreeCommitter
}

/// Accumulates step 9's outcome across every held Worktree. A class, not `inout`, for the same
/// parameter-count reason as ``WorktreeRemovalContext``.
private final class WorktreeRemovalOutcome {
    var releasedWorktreeIDs: [Int64] = []
    var failures: [String] = []
}

extension ProjectRemoval {
    /// Step 7: posts the deterministic ``ProjectRemovalComment`` on the in-flight Feature Issue.
    /// Deterministic on `feature.issueID` (`OutboxClientID.make`, salted by the Journal that computed
    /// `clientID`), so a re-run of the same Journal after a partial failure replays the same comment
    /// rather than duplicating it. A board error is a step failure.
    func postRemovalComment(
        feature: FeatureRecord, clientID: UUID, body: String,
        bindBoard: () throws -> any BoardWriting, failures: inout [String]
    ) async {
        let issue = BoardObjectID(rawValue: feature.issueID)
        do {
            let board = try bindBoard()
            _ = try await board.createComment(on: issue, body: body, clientID: clientID)
        } catch {
            failures.append("could not comment on \(feature.issueID): \(error)") // glossary:ignore GL001
        }
    }

    /// Step 8: the `NightMode` of the Night the in-flight Feature was selected in, `.rehearsal` (the
    /// safe side — it never commits or pushes) when that cannot be resolved.
    func resolveMode(journal: JournalStore) -> NightMode {
        guard
            let inFlight = try? journal.inFlightFeature(),
            let selectedNightID = try? journal.selectedNightID(featureID: inFlight.feature.id),
            let night = try? journal.night(id: selectedNightID)
        else {
            return .rehearsal
        }
        return night.mode
    }

    /// Step 9: WIP-commits, pushes and removes every held Worktree. Worktrees this call could not
    /// resolve or that failed are left held and reported as step failures; a rehearsal-mode Worktree
    /// left dirty on purpose is reported but is not a failure.
    func removeWorktrees(
        journal: JournalStore, project: ProjectConfiguration, mode: NightMode,
        push: @escaping @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome
    ) async -> WorktreeRemovalResult {
        guard let worktrees = try? journal.heldWorktrees() else {
            return WorktreeRemovalResult(releasedWorktreeIDs: [], failures: ["could not read held Worktrees"])
        }
        let context = WorktreeRemovalContext(
            journal: journal, project: project, mode: mode, push: push,
            committer: WorktreeCommitter(git: git, mode: mode, message: project.wipCommit)
        )
        let outcome = WorktreeRemovalOutcome()
        for worktree in worktrees {
            await removeWorktree(worktree, context: context, outcome: outcome)
        }
        return WorktreeRemovalResult(releasedWorktreeIDs: outcome.releasedWorktreeIDs, failures: outcome.failures)
    }

    private func removeWorktree(
        _ worktree: WorktreeRecord, context: WorktreeRemovalContext, outcome: WorktreeRemovalOutcome
    ) async {
        guard
            let feature = try? context.journal.feature(id: worktree.featureID),
            let branch = try? context.journal.resolvedFeatureBranch(feature: feature, repository: worktree.repository)
        else {
            outcome.failures.append(
                "Worktree \(worktree.id) (\(worktree.repository)): no recorded Feature Branch" // glossary:ignore GL001
            )
            return
        }
        guard let repo = context.project.repositories.workingRepo(named: worktree.repository) else {
            outcome.failures.append(
                "Worktree \(worktree.id): no repository named \"\(worktree.repository)\" is configured"
            )
            return
        }

        switch await context.committer.commitWIP(
            worktreePath: worktree.path, branch: branch, repository: worktree.repository
        ) {
        case .committed:
            await pushThenRemove(worktree, branch: branch, repo: repo, context: context, outcome: outcome)
        case .noChanges(let headCommit, _, _) where headCommit == worktree.pushedCommit:
            await finishRemoval(worktree, outcome: outcome)
        case .noChanges:
            await pushThenRemove(worktree, branch: branch, repo: repo, context: context, outcome: outcome)
        case .refused(let reason) where context.mode == .rehearsal && Self.isRehearsalDirtyRefusal(reason):
            output(
                "Worktree \(worktree.id) (\(worktree.repository)): uncommitted edits left in " // glossary:ignore GL001
                    + "place: a rehearsal Night never commits"
            )
        case .refused(let reason):
            await removeIfPathMissingElseFail(worktree, reason: reason, outcome: outcome)
        case .failed(let reason):
            await removeIfPathMissingElseFail(worktree, reason: reason, outcome: outcome)
        }
    }

    private static func isRehearsalDirtyRefusal(_ reason: String) -> Bool {
        reason.contains("a rehearsal Night never commits")
    }

    /// Pushes the branch and removes the Worktree on `.pushed`; any other outcome is a failure that
    /// keeps the Worktree. A rehearsal Night never pushes (only a clean `.noChanges` tree reaches here
    /// in rehearsal, since `.committed` never occurs there), so the tip is instead pinned under
    /// `refs/yellowhammer/removed/<branch>` before removal: Orca ADE deletes the local branch with the
    /// Worktree, and commits are never destroyed.
    private func pushThenRemove(
        _ worktree: WorktreeRecord, branch: FeatureBranch, repo: Repo, context: WorktreeRemovalContext,
        outcome: WorktreeRemovalOutcome
    ) async {
        guard context.mode == .real else {
            guard await pinTip(of: worktree, branch: branch) else {
                outcome.failures.append(
                    "Worktree \(worktree.id) (\(worktree.repository)): " // glossary:ignore GL001
                        + "could not pin its unpushed tip under \(Self.removedRef(branch))"
                )
                return
            }
            await finishRemoval(worktree, outcome: outcome)
            return
        }
        let pushOutcome = await context.push(branch, repo, context.mode)
        guard case .pushed = pushOutcome else {
            outcome.failures.append(
                "Worktree \(worktree.id) (\(worktree.repository)): push did not succeed: " // glossary:ignore GL001
                    + "\(pushOutcome)"
            )
            return
        }
        await finishRemoval(worktree, outcome: outcome)
    }

    /// The ref an unpushed rehearsal Feature Branch tip is kept at once its Worktree is removed.
    static func removedRef(_ branch: FeatureBranch) -> String {
        "refs/yellowhammer/removed/\(branch.name)"
    }

    private func pinTip(of worktree: WorktreeRecord, branch: FeatureBranch) async -> Bool {
        let path = (worktree.path as NSString).expandingTildeInPath
        let result = await git.run(["-C", path, "update-ref", Self.removedRef(branch), "HEAD"])
        return result.isSuccess
    }

    /// Tries removal even when the Worktree path is already gone (Orca ADE may still hold bookkeeping
    /// for it); otherwise this is a step failure that leaves the Worktree in place.
    private func removeIfPathMissingElseFail(
        _ worktree: WorktreeRecord, reason: String, outcome: WorktreeRemovalOutcome
    ) async {
        let path = (worktree.path as NSString).expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: path) else {
            outcome.failures.append("Worktree \(worktree.id) (\(worktree.repository)): \(reason)")
            return
        }
        await finishRemoval(worktree, outcome: outcome)
    }

    /// `.worktreeNotFound` counts as removed — Orca ADE already has no record of it. Any other error is
    /// a step failure that leaves the Worktree recorded as held.
    private func finishRemoval(_ worktree: WorktreeRecord, outcome: WorktreeRemovalOutcome) async {
        do {
            try await workspace.removeWorktree(id: WorktreeID(rawValue: worktree.worktreeID), force: false)
            outcome.releasedWorktreeIDs.append(worktree.id)
        } catch WorkspaceError.worktreeNotFound {
            outcome.releasedWorktreeIDs.append(worktree.id)
        } catch {
            outcome.failures.append("Worktree \(worktree.id) (\(worktree.repository)): could not remove: \(error)")
        }
    }
}
