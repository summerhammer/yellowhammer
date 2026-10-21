import Domain
import Foundation
import Journal
import Repositories

/// The base a new Worktree is cut from when the Feature recorded one for the repository at selection.
struct RecordedBaseCut: Sendable {
    /// What `--base-branch` is given.
    let ref: String
    /// The recorded `baseCommit`; the new Worktree's initial HEAD must equal it.
    let expected: String
    /// Whether ``ref`` is a ``RecordedBasePin`` ref to delete once the Worktree exists.
    let pinned: Bool
}

// Stacked Worktree allocation on `effective_base(R)` (roadmap P23.3; spec:
// graph-execution/allocate-a-worktree-per-graph-and-repo, feature-authoring/select-the-next-feature
// `#effective-base`): every Worktree of a Feature is cut from the base recorded at selection, never from
// one computed later. A repository with no `feature_base` row keeps Orca ADE's default base.
extension WorktreeAllocator {
    private static let landedPrefix = "refs/yellowhammer/landed/"

    /// The cut for `repo`, nil when the Feature recorded no base there. A stacked record is cut from its
    /// landed-tip pin, else the remote-tracking `refs/remotes/origin/<b_last>`; an unstacked one is cut from a
    /// pin of its `baseCommit`. A pin that cannot be written throws
    /// ``WorktreeAllocationError/recordedBaseMismatch(repository:ref:expected:found:)`` before any Worktree is made.
    func recordedBaseCut(
        featureID: Int64, repo: Repo, repositoryPath: String, worktreeName: WorktreeName
    ) async throws -> RecordedBaseCut? {
        guard let record = try journal.featureBases(featureID: featureID).first(where: { $0.repository == repo.name })
        else { return nil }

        if record.stackedOnFeatureID != nil {
            if await resolves(record.baseRef, in: repositoryPath) {
                return RecordedBaseCut(ref: record.baseRef, expected: record.baseCommit, pinned: false)
            }
            let branch = record.baseRef.hasPrefix(Self.landedPrefix)
                ? String(record.baseRef.dropFirst(Self.landedPrefix.count)) : record.baseRef
            return RecordedBaseCut(
                ref: "refs/remotes/origin/\(branch)", expected: record.baseCommit, pinned: false
            )
        }

        let pin = RecordedBasePin(git: git)
        guard case .done = await pin.pin(
            commit: record.baseCommit, worktreeName: worktreeName.rawValue, repositoryPath: repositoryPath
        ) else {
            throw WorktreeAllocationError.recordedBaseMismatch(
                repository: repo.name, ref: RecordedBasePin.ref(for: worktreeName.rawValue),
                expected: record.baseCommit, found: nil
            )
        }
        return RecordedBaseCut(
            ref: RecordedBasePin.ref(for: worktreeName.rawValue), expected: record.baseCommit, pinned: true
        )
    }

    /// Strict (a nil `cut` — no record, or a recovery pin in use — checks nothing): the new Worktree's initial HEAD must equal the recorded `baseCommit`; an unresolvable HEAD is a
    /// mismatch. On mismatch the Worktree Orca ADE made is removed, the Journal is untouched and
    /// ``WorktreeAllocationError/recordedBaseMismatch(repository:ref:expected:found:)`` is thrown.
    func verifyRecordedBase(
        _ cut: RecordedBaseCut?, found: String?, worktree: WorkspaceWorktree, repository: String
    ) async throws {
        guard let cut, found != cut.expected else { return }
        _ = try? await workspace.removeWorktree(id: worktree.id, force: true)
        throw WorktreeAllocationError.recordedBaseMismatch(
            repository: repository, ref: cut.ref, expected: cut.expected, found: found
        )
    }

    /// Asks Orca ADE for the Worktree on `baseBranch`; the ``RecordedBasePin`` is only needed for the call, so it
    /// is dropped whether or not the call succeeded. A Workspace failure is wrapped as
    /// ``WorktreeAllocationError/workspace(repository:_:)``.
    func createWorktree(
        repo: Repo, repositoryPath: String, worktreeName: WorktreeName, baseBranch: String?,
        recordedBase: RecordedBaseCut?
    ) async throws -> WorkspaceWorktree {
        let result: Result<WorkspaceWorktree, WorkspaceError>
        do {
            result = .success(try await workspace.createWorktree(
                repositoryPath: repositoryPath, name: worktreeName.rawValue, baseBranch: baseBranch
            ))
        } catch {
            result = .failure(error)
        }
        await dropBasePin(recordedBase, worktreeName: worktreeName, repositoryPath: repositoryPath)
        return try result.mapError { WorktreeAllocationError.workspace(repository: repo.name, $0) }.get()
    }

    /// Deletes the ``RecordedBasePin`` once the Worktree exists (or could not be made): only the creation needs it.
    func dropBasePin(_ cut: RecordedBaseCut?, worktreeName: WorktreeName, repositoryPath: String) async {
        guard cut?.pinned == true else { return }
        await RecordedBasePin(git: git).unpin(worktreeName: worktreeName.rawValue, repositoryPath: repositoryPath)
    }

    private func resolves(_ ref: String, in repositoryPath: String) async -> Bool {
        await git.run(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]).isSuccess
    }
}
