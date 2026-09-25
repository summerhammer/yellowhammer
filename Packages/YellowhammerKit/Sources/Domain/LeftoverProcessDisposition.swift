import Foundation

/// What happened to one process a Card run's leftover accounting named (Normal-Exit Sweep Ruling,
/// issue #175): layer 1 is the agent CLI process lifecycle's own sweep, by identity, of a normal
/// exit's cumulative descendant snapshot; layer 2 is the attributed Worktree fence the Engine runs
/// against that snapshot before the next step of the same Card run.
public enum LeftoverProcessDisposition: String, CaseIterable, Sendable {
    /// Layer 1: the agent CLI process lifecycle swept it by identity, from the running snapshot,
    /// after the CLI leader exited normally.
    case sweptByRunningSnapshot = "swept-by-running-snapshot"
    /// Layer 2: the attributed Worktree fence found it still holding the Worktree, attributed it to
    /// this run's snapshot, and killed it.
    case sweptByWorktreeFence = "swept-by-worktree-fence"
    /// Layer 2: the attributed Worktree fence found it holding the Worktree but could not attribute
    /// it to this run's snapshot, so it was left running.
    case leftRunningUnattributed = "left-running-unattributed"
}
