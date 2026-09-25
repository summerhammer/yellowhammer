import Domain
import Repositories

/// The seam ``CardRun`` calls after every pass whose report carries a running snapshot (Normal-Exit
/// Sweep Ruling, layer 2, issue #175): the attributed Worktree fence, run against the snapshot
/// ``AgentCLIProcess`` captured while the agent CLI leader was still alive. Layer 1 — the process
/// lifecycle's own sweep of that snapshot, by identity, right after the leader exits — has already
/// run by the time this seam is called; this is what catches a process the layer-1 sweep never saw,
/// because it was still holding the Worktree by cwd or open file rather than being a tracked
/// descendant. Pure process-table work, mirroring ``AttemptResetting``'s seam over ``ProcessFencer``:
/// Journal writes stay in ``CardRun``.
public protocol NormalExitFencing: Sendable {
    func fence(worktreePath: String, attributedTo snapshot: RunningSnapshot) async -> AttributedFencingOutcome
}

/// The real ``NormalExitFencing``: the attributed Worktree fence, over ``ProcessFencer``.
public struct AttributedWorktreeFence: NormalExitFencing {
    public let fencer: ProcessFencer

    public init(fencer: ProcessFencer = ProcessFencer()) {
        self.fencer = fencer
    }

    public func fence(worktreePath: String, attributedTo snapshot: RunningSnapshot) async -> AttributedFencingOutcome {
        await fencer.fence(worktreePath: worktreePath, attributedTo: snapshot)
    }
}
