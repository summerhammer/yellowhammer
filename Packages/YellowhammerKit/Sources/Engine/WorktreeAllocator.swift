import Domain
import Foundation
import Journal
import Repositories

/// The Worktrees held for one Feature, one per repository.
public struct FeatureWorktrees: Equatable, Sendable {
    private let byRepository: [String: WorktreeRecord]

    public init(_ byRepository: [String: WorktreeRecord] = [:]) {
        self.byRepository = byRepository
    }

    /// The held Worktree for `repository`, when one is allocated. This is how a Card resolves the
    /// Worktree it works in.
    public subscript(repository: String) -> WorktreeRecord? {
        byRepository[repository]
    }

    public var repositories: [String] { byRepository.keys.sorted() }
    public var count: Int { byRepository.count }
}

/// A failure allocating or releasing a Feature's Worktrees.
public enum WorktreeAllocationError: Error, Equatable, Sendable {
    /// Orca ADE reported a branch for `repository` that is not acceptable. `requested` is the Worktree
    /// name asked of Orca ADE; `reported` is the branch Orca ADE reported; `recorded` is the Feature
    /// Branch already recorded for the pair, nil on a first allocation. The Worktree it made was
    /// removed and nothing was written to the Journal before this was thrown.
    case nameCollision(repository: String, requested: String, reported: String, recorded: String?)
    /// A Worktree re-allocated from a recovery pin (OQ123) did not come back at the recorded commit:
    /// `branch` is what Orca ADE reported, `expected` is the recorded recovery commit and `found` is the
    /// new Worktree's HEAD, nil when it did not resolve. The Worktree it made was removed; the pin and the
    /// Journal's recovery record are untouched, so the commits are still held. Deliberately not
    /// ``nameCollision(repository:requested:reported:recorded:)``: that one's remedy is a prefix change.
    case recoveryMismatch(repository: String, branch: String, expected: String, found: String?)
    /// The Worktree held for `repository` cannot be released: its Feature Branch has not been pushed.
    case notPushed(repository: String)
    /// No Worktree is held for `repository`.
    case notHeld(repository: String)
    /// The Workspace Port refused or could not honor the request for `repository`.
    case workspace(repository: String, WorkspaceError)
}

extension WorktreeAllocationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nameCollision(let repository, let requested, let reported, let recorded):
            if let recorded {
                "Orca ADE reported branch '\(reported)' for Worktree '\(requested)' in \(repository), " +
                    "but the Feature Branch recorded there is '\(recorded)'"
            } else {
                "Orca ADE reported branch '\(reported)' for Worktree '\(requested)' in \(repository); " +
                    "it is neither that name nor '<prefix>/' followed by it"
            }
        case .recoveryMismatch(let repository, let branch, let expected, let found):
            "Re-allocating the Worktree for \(repository) from its recovery pin gave branch '\(branch)' at " +
                "\(found ?? "an unresolvable HEAD"), not the recorded recovery commit \(expected); " +
                "the Worktree was removed and the pin kept"
        case .notPushed(let repository):
            "The Worktree held for \(repository) cannot be released: its Feature Branch has not been pushed"
        case .notHeld(let repository):
            "No Worktree is held for \(repository)"
        case .workspace(let repository, let error):
            "The Workspace Port failed for \(repository): \(error)"
        }
    }
}

/// Allocates and releases the Worktrees a Feature needs, one per repository
/// (graph-execution/allocate-a-worktree-per-graph-and-repo).
///
/// Orca ADE owns Worktrees: it creates, places and removes them. Yellowhammer requests one by Worktree
/// name (`yh-<project>-<feature>`) and records the Feature Branch Orca ADE reports, per (Feature,
/// repository); it never renames that branch. This holds only what sits above the Workspace Port — the
/// check on the reported branch, the `git worktree prune` run in the repository before each new
/// allocation, reuse of a Worktree already held for a Feature's repository, and the release gate on an
/// unpushed Feature Branch. It never creates, places or deletes a worktree itself. After a ghost-Worktree
/// purge pinned the Feature Branch tip (OQ123), re-allocation is based on that pin and verified against
/// the recorded commit before the pin is dropped.
public struct WorktreeAllocator: Sendable {
    public let workspace: any Workspace
    public let journal: JournalStore
    public let runID: RunID
    public let git: GitRunner
    /// Deletes the recovery pin once a re-allocation from it is verified and recorded (OQ123).
    public let recoveryPin: FeatureBranchRecoveryPin

    public init(
        workspace: any Workspace,
        journal: JournalStore,
        runID: RunID,
        git: GitRunner = GitRunner(),
        recoveryPin: FeatureBranchRecoveryPin? = nil
    ) {
        self.workspace = workspace
        self.journal = journal
        self.runID = runID
        self.git = git
        self.recoveryPin = recoveryPin ?? FeatureBranchRecoveryPin(git: git)
    }

    /// Allocates one Worktree per `repos`, in the given order. A repository that already holds a
    /// Worktree for this Feature reuses it, with no Orca ADE call and no prune. Otherwise `git
    /// worktree prune` runs first (best-effort: its failure does not stop allocation), then Orca ADE
    /// is asked for a Worktree named `worktreeName`.
    ///
    /// Exactly one rule judges the reported branch (``accepts(reported:worktreeName:recorded:)``): when
    /// a Feature Branch is already recorded for the repository it must equal it exactly; when none is,
    /// it must be `worktreeName` or `<prefix>/` followed by it (Orca ADE's branch-name prefix, which may
    /// contain `/`). Otherwise the Worktree Orca ADE made is removed, nothing is written to the Journal,
    /// and ``WorktreeAllocationError/nameCollision(repository:requested:reported:recorded:)`` is thrown.
    /// On success the Worktree and the reported Feature Branch are recorded in one Journal transaction.
    ///
    /// The Worktree's HEAD is resolved and recorded as its last known-good commit (object-guide:
    /// Worktree.last_known_good_commit, set "at allocation") — best-effort: a Worktree the Workspace
    /// Port did not check out to a real commit (a fake in a test) resolves to nil rather than failing
    /// allocation. With a recovery commit outstanding the Worktree is instead based on the recovery pin
    /// and its HEAD must equal that commit (see ``allocateNew(featureID:worktreeName:repo:)``).
    public func allocate(
        featureID: Int64, worktreeName: WorktreeName, repos: [Repo]
    ) async throws -> FeatureWorktrees {
        var byRepository: [String: WorktreeRecord] = [:]

        for repo in repos {
            if let held = try journal.heldWorktree(featureID: featureID, repository: repo.name) {
                byRepository[repo.name] = held
                continue
            }

            byRepository[repo.name] = try await allocateNew(
                featureID: featureID, worktreeName: worktreeName, repo: repo
            )
        }

        return FeatureWorktrees(byRepository)
    }

    /// Asks Orca ADE for a new Worktree in `repo` and records it. When a recovery commit is outstanding
    /// for the pair (a ghost-Worktree purge pinned the Feature Branch tip; OQ123) and a Feature Branch is
    /// recorded, the same `--name` is requested with `--base-branch refs/yellowhammer/recovery/<branch>`,
    /// the new Worktree's HEAD must equal that commit, and only then is the recovery cleared — in the same
    /// Journal transaction that records the Worktree — before the pin ref is deleted best-effort (a
    /// leftover pin is harmless; a cleared pin ahead of a recorded Worktree is not). A HEAD that does not
    /// match, or does not resolve, removes the Worktree Orca ADE made, leaves the pin and the Journal
    /// untouched and throws ``WorktreeAllocationError/recoveryMismatch(repository:branch:expected:found:)``.
    private func allocateNew(featureID: Int64, worktreeName: WorktreeName, repo: Repo) async throws -> WorktreeRecord {
        let recorded = try journal.featureBranch(featureID: featureID, repository: repo.name)
        let recovery = try journal.recoveryCommit(featureID: featureID, repository: repo.name)
        let pinned = recorded.flatMap { branch in recovery.map { (branch: branch, commit: $0) } }
        let repositoryPath = Self.expandedPath(repo.path)
        _ = await git.run(["worktree", "prune"], workingDirectory: repositoryPath)

        let worktree: WorkspaceWorktree
        do {
            worktree = try await workspace.createWorktree(
                repositoryPath: repositoryPath, name: worktreeName.rawValue,
                baseBranch: pinned.map { FeatureBranchRecoveryPin.ref(for: $0.branch) }
            )
        } catch {
            throw WorktreeAllocationError.workspace(repository: repo.name, error)
        }

        guard Self.accepts(reported: worktree.branch, worktreeName: worktreeName, recorded: recorded) else {
            _ = try? await workspace.removeWorktree(id: worktree.id, force: true)
            throw WorktreeAllocationError.nameCollision(
                repository: repo.name, requested: worktreeName.rawValue, reported: worktree.branch,
                recorded: recorded?.rawValue
            )
        }

        let lastKnownGoodCommit = await Self.resolveHead(git: git, path: worktree.path)
        if let pinned {
            try await verifyRecovery(
                pinned.commit, found: lastKnownGoodCommit, worktree: worktree, repository: repo.name
            )
        }

        let record: WorktreeRecord
        do {
            record = try journal.recordWorktree(
                featureID: featureID,
                repository: repo.name,
                worktreeID: worktree.id.rawValue,
                path: worktree.path,
                runID: runID,
                lastKnownGoodCommit: lastKnownGoodCommit,
                featureBranch: FeatureBranch(name: worktree.branch),
                clearingRecoveryCommit: pinned?.commit
            )
        } catch JournalError.featureBranchConflict(_, _, let conflicting, let reported) {
            _ = try? await workspace.removeWorktree(id: worktree.id, force: true)
            throw WorktreeAllocationError.nameCollision(
                repository: repo.name, requested: worktreeName.rawValue, reported: reported,
                recorded: conflicting
            )
        }

        if let pinned {
            _ = await recoveryPin.unpin(pinned.commit, branch: pinned.branch, repositoryPath: repositoryPath)
        }
        return record
    }

    /// Strict: a new Worktree based on a recovery pin must sit exactly at the recorded `expected` commit; an
    /// unresolvable HEAD (`found` nil) is a mismatch. On mismatch the Worktree Orca ADE made is removed
    /// and ``WorktreeAllocationError/recoveryMismatch(repository:branch:expected:found:)`` is thrown.
    private func verifyRecovery(
        _ expected: String, found: String?, worktree: WorkspaceWorktree, repository: String
    ) async throws {
        guard found != expected else { return }
        _ = try? await workspace.removeWorktree(id: worktree.id, force: true)
        throw WorktreeAllocationError.recoveryMismatch(
            repository: repository, branch: worktree.branch, expected: expected, found: found
        )
    }

    /// Releases the Worktree held for `featureID`'s `repository`. Refuses with
    /// ``WorktreeAllocationError/notPushed(repository:)`` before any Orca ADE call unless the Feature
    /// Branch has been recorded pushed — unless `discardingUnpushedWork` says otherwise (the settle
    /// gesture's *released* value, roadmap P10.9: "abandons the unmerged pull requests on our side" is
    /// never softer than abandoning a Worktree that never got that far). A Worktree Orca ADE has
    /// already lost track of is tolerated: it is already gone, so the Journal still records the release.
    @discardableResult
    public func release(
        featureID: Int64, repository: String, discardingUnpushedWork: Bool = false
    ) async throws -> WorktreeRecord {
        guard let held = try journal.heldWorktree(featureID: featureID, repository: repository) else {
            throw WorktreeAllocationError.notHeld(repository: repository)
        }
        guard held.pushedCommit != nil || discardingUnpushedWork else {
            throw WorktreeAllocationError.notPushed(repository: repository)
        }

        do {
            try await workspace.removeWorktree(id: WorktreeID(rawValue: held.worktreeID), force: true)
        } catch WorkspaceError.worktreeNotFound {
            // Orca ADE already has no record of it; still mark released.
        } catch {
            throw WorktreeAllocationError.workspace(repository: repository, error)
        }

        return try journal.releaseWorktree(
            id: held.id, runID: runID, discardingUnpushedWork: discardingUnpushedWork
        )
    }

    /// Whether `reported` is an acceptable branch for a Worktree requested as `worktreeName`. With a
    /// `recorded` Feature Branch it must equal it exactly; without one it must be `worktreeName` or end
    /// with `/` followed by it.
    static func accepts(reported: String, worktreeName: WorktreeName, recorded: FeatureBranch?) -> Bool {
        if let recorded {
            return reported == recorded.rawValue
        }
        return reported == worktreeName.rawValue || reported.hasSuffix("/" + worktreeName.rawValue)
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Resolves `path`'s HEAD commit, nil if it does not resolve (e.g. a fake Workspace's plain
    /// directory in a test) rather than failing allocation over it.
    private static func resolveHead(git: GitRunner, path: String) async -> String? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}
