import Domain
import Foundation

/// The comment posted on the in-flight Feature Card when explicit Project removal (roadmap P13.5;
/// spec risks.md OQ52(1)) releases it. Pure: no Journal or board access. States plainly that
/// Yellowhammer's automated management stopped, that nothing on Linear was deleted, and that any
/// Worktree with uncommitted edits got a WIP commit pushed to the Feature Branch before removal — a
/// statement of removal's policy, not a per-repository report (removal posts this comment before it
/// walks the held Worktrees, so it cannot yet name which of them had edits).
public struct ProjectRemovalComment: Equatable, Sendable {
    public let projectID: ProjectID
    /// The mode the Feature's Night ran in: a rehearsal Night never commits into a Worktree or pushes,
    /// so the Worktree sentence differs.
    public let mode: NightMode

    public init(projectID: ProjectID, mode: NightMode) {
        self.projectID = projectID
        self.mode = mode
    }

    public func body() -> String {
        let worktrees = switch mode {
        case .real:
            "Any Worktree that still had uncommitted edits was given a WIP commit, pushed to its Feature "
                + "Branch, before its Worktree was removed."
        case .rehearsal:
            "This was a rehearsal Night, which never commits or pushes: a Worktree with uncommitted edits "
                + "was left in place, and nothing was pushed."
        }
        return """
        **Project removed.** Yellowhammer's automated management of Project \(projectID.rawValue) was \
        released because the Project was removed on this machine. This Feature Card, its Work Cards and \
        every other object on Linear are untouched — nothing here was deleted, and this Feature Card is no \
        longer in flight for Yellowhammer. \(worktrees)
        """
    }
}
