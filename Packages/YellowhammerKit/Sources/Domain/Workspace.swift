import Foundation

/// The Workspace Port (ADR-001): how Yellowhammer asks for the Worktrees it needs.
///
/// Orca ADE owns Worktrees — it creates, places and removes them; Yellowhammer never creates, places
/// or deletes one itself, and holds only the opaque id and path it is handed back, in the Journal.
///
/// The Port is not the policy. The collision check on a name Orca ADE could not honor, the
/// `git worktree prune` run in the repository before each new allocation, reuse of a Worktree already
/// held for a Feature's repository, and the release gate on an unpushed Feature Branch all sit above
/// it, in the Engine and the Journal; an implementation translates and never decides.
public protocol Workspace: Sendable {
    /// Asks Orca ADE for a Worktree of `repositoryPath`, named `name`, based on `baseBranch` when one
    /// is given. Orca ADE creates a branch identical to `name` when it can; on a name collision it
    /// does not fail — it returns a Worktree whose `branch` differs from `name`, and the caller
    /// judges that, not this Port.
    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree

    /// Every Worktree Orca ADE holds for `repositoryPath`, the main checkout excluded.
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree]

    /// Removes a Worktree Orca ADE holds. Removal also deletes its local branch.
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError)
}

/// An opaque identifier Orca ADE assigns a Worktree. Yellowhammer never parses it.
public struct WorktreeID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension WorktreeID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// One Worktree as Orca ADE reports it.
public struct WorkspaceWorktree: Hashable, Sendable {
    public let id: WorktreeID
    public let path: String
    /// The branch Orca ADE created for it, without the `refs/heads/` prefix.
    public let branch: String
    public let displayName: String

    public init(id: WorktreeID, path: String, branch: String, displayName: String) {
        self.id = id
        self.path = path
        self.branch = branch
        self.displayName = displayName
    }
}

/// A refusal, unavailability, or malformed response from the Workspace Port.
public enum WorkspaceError: Error, Equatable, Sendable {
    /// The repository is not registered with Orca ADE.
    case repositoryNotRegistered(path: String)
    /// Orca ADE has no Worktree with this id.
    case worktreeNotFound(WorktreeID)
    /// Orca ADE refused the request for another reason, carrying its vendor error code.
    case refused(code: String, message: String)
    /// The `orca` executable could not be launched, or its runtime could not be reached.
    case unavailable(String)
    /// Orca ADE's response could not be read.
    case malformedResponse(String)
}

extension WorkspaceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .repositoryNotRegistered(let path):
            "Orca ADE has no repository registered at \(path)"
        case .worktreeNotFound(let id):
            "Orca ADE has no Worktree with id \(id)"
        case .refused(let code, let message):
            "Orca ADE refused the request (\(code)): \(message)"
        case .unavailable(let reason):
            "Orca ADE could not be reached: \(reason)"
        case .malformedResponse(let reason):
            "Orca ADE's response could not be read: \(reason)"
        }
    }
}
