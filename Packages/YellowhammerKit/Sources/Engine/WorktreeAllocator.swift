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
    /// Orca ADE could not honor the requested branch name for `repository`: `created` is what it made
    /// instead. The Worktree it made was removed before this was thrown.
    case nameCollision(repository: String, requested: String, created: String)
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
        case .nameCollision(let repository, let requested, let created):
            "Orca ADE could not create branch '\(requested)' in \(repository); it created '\(created)' instead"
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
/// Orca ADE owns Worktrees: it creates, places and removes them. This holds only what sits above the
/// Workspace Port — the collision check on a name Orca ADE could not honor, the `git worktree prune`
/// run in the repository before each new allocation, reuse of a Worktree already held for a Feature's
/// repository, and the release gate on an unpushed Feature Branch. It never creates, places or
/// deletes a worktree itself.
public struct WorktreeAllocator: Sendable {
    public let workspace: any Workspace
    public let journal: JournalStore
    public let runID: RunID
    public let git: GitRunner

    public init(
        workspace: any Workspace,
        journal: JournalStore,
        runID: RunID,
        git: GitRunner = GitRunner()
    ) {
        self.workspace = workspace
        self.journal = journal
        self.runID = runID
        self.git = git
    }

    /// Allocates one Worktree per `repos`, in the given order. A repository that already holds a
    /// Worktree for this Feature reuses it, with no Orca ADE call and no prune. Otherwise `git
    /// worktree prune` runs first (best-effort: its failure does not stop allocation), then Orca ADE
    /// is asked for a Worktree named after `branch`. A returned branch other than `branch.name` is a
    /// collision Orca ADE could not honor: the Worktree it made is removed and
    /// ``WorktreeAllocationError/nameCollision(repository:requested:created:)`` is thrown.
    ///
    /// The Worktree's HEAD is resolved and recorded as its last known-good commit (object-guide:
    /// Worktree.last_known_good_commit, set "at allocation") — best-effort: a Worktree the Workspace
    /// Port did not check out to a real commit (a fake in a test) resolves to nil rather than failing
    /// allocation.
    public func allocate(
        featureID: Int64, branch: FeatureBranch, repos: [Repo]
    ) async throws -> FeatureWorktrees {
        var byRepository: [String: WorktreeRecord] = [:]

        for repo in repos {
            if let held = try journal.heldWorktree(featureID: featureID, repository: repo.name) {
                byRepository[repo.name] = held
                continue
            }

            let repositoryPath = Self.expandedPath(repo.path)
            _ = await git.run(["worktree", "prune"], workingDirectory: repositoryPath)

            let worktree: WorkspaceWorktree
            do {
                worktree = try await workspace.createWorktree(
                    repositoryPath: repositoryPath, name: branch.name, baseBranch: nil
                )
            } catch {
                throw WorktreeAllocationError.workspace(repository: repo.name, error)
            }

            guard worktree.branch == branch.name else {
                _ = try? await workspace.removeWorktree(id: worktree.id, force: true)
                throw WorktreeAllocationError.nameCollision(
                    repository: repo.name, requested: branch.name, created: worktree.branch
                )
            }

            let lastKnownGoodCommit = await Self.resolveHead(git: git, path: worktree.path)
            let record = try journal.recordWorktree(
                featureID: featureID,
                repository: repo.name,
                worktreeID: worktree.id.rawValue,
                path: worktree.path,
                runID: runID,
                lastKnownGoodCommit: lastKnownGoodCommit
            )
            byRepository[repo.name] = record
        }

        return FeatureWorktrees(byRepository)
    }

    /// Releases the Worktree held for `featureID`'s `repository`. Refuses with
    /// ``WorktreeAllocationError/notPushed(repository:)`` before any Orca ADE call unless the Feature
    /// Branch has been recorded pushed. A Worktree Orca ADE has already lost track of is tolerated:
    /// it is already gone, so the Journal still records the release.
    @discardableResult
    public func release(featureID: Int64, repository: String) async throws -> WorktreeRecord {
        guard let held = try journal.heldWorktree(featureID: featureID, repository: repository) else {
            throw WorktreeAllocationError.notHeld(repository: repository)
        }
        guard held.pushedCommit != nil else {
            throw WorktreeAllocationError.notPushed(repository: repository)
        }

        do {
            try await workspace.removeWorktree(id: WorktreeID(rawValue: held.worktreeID), force: true)
        } catch WorkspaceError.worktreeNotFound {
            // Orca ADE already has no record of it; still mark released.
        } catch {
            throw WorktreeAllocationError.workspace(repository: repository, error)
        }

        return try journal.releaseWorktree(id: held.id, runID: runID)
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
