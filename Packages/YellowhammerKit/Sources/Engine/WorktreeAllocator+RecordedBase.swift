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
}

// Stacked Worktree allocation on `effective_base(R)` (roadmap P23.3; spec:
// graph-execution/allocate-a-worktree-per-graph-and-repo, feature-authoring/select-the-next-feature
// `#effective-base`): every Worktree of a Feature is cut from the base recorded at selection, never from
// one computed later.
extension WorktreeAllocator {
    private static let landedPrefix = "refs/yellowhammer/landed/"

    /// The cut for `repo`. A stacked record is cut from its landed-tip pin, else the remote-tracking
    /// `refs/remotes/origin/<b_last>`; an unstacked one is cut directly from `baseCommit` (Orca ADE's
    /// `--base-branch` accepts a bare commit SHA).
    /// Throws ``WorktreeAllocationError/missingRecordedBase(repository:)`` when no base was recorded for the repository.
    func recordedBaseCut(
        featureID: Int64, repo: Repo, repositoryPath: String, worktreeName: WorktreeName
    ) async throws -> RecordedBaseCut {
        guard let record = try journal.featureBases(featureID: featureID).first(where: { $0.repository == repo.name })
        else {
            throw WorktreeAllocationError.missingRecordedBase(repository: repo.name)
        }

        if record.stackedOnFeatureID != nil {
            if await resolves(record.baseRef, in: repositoryPath) {
                return RecordedBaseCut(ref: record.baseRef, expected: record.baseCommit)
            }
            let branch = record.baseRef.hasPrefix(Self.landedPrefix)
                ? String(record.baseRef.dropFirst(Self.landedPrefix.count)) : record.baseRef
            return RecordedBaseCut(
                ref: "refs/remotes/origin/\(branch)", expected: record.baseCommit
            )
        }

        return RecordedBaseCut(ref: record.baseCommit, expected: record.baseCommit)
    }

    /// Strict (a nil `cut` — a recovery pin in use — checks nothing): the new Worktree's initial HEAD must equal the recorded `baseCommit`; an unresolvable HEAD is a
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

    /// Asks Orca ADE for the Worktree on `baseBranch`. A Workspace failure is wrapped as
    /// ``WorktreeAllocationError/workspace(repository:_:)``.
    func createWorktree(
        repo: Repo, repositoryPath: String, worktreeName: WorktreeName, baseBranch: String?,
        recordedBase: RecordedBaseCut?
    ) async throws -> WorkspaceWorktree {
        do {
            return try await workspace.createWorktree(
                repositoryPath: repositoryPath, name: worktreeName.rawValue, baseBranch: baseBranch
            )
        } catch {
            throw WorktreeAllocationError.workspace(repository: repo.name, error)
        }
    }

    private func resolves(_ ref: String, in repositoryPath: String) async -> Bool {
        await git.run(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]).isSuccess
    }
}
