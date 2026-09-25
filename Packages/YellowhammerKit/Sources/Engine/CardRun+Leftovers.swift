import Domain
import Foundation
import Journal
import Repositories

// The Normal-Exit Sweep Ruling's leftover accounting (issue #175): what `runPass` calls right after
// a report comes back, before that pass's outcome is recorded or an `AttemptEnding` is thrown — a
// non-zero self-exit is still a normal exit, and its leftovers are still swept.

extension CardRunFrame {
    /// Records one leftover process against this Card's Attempt and pass, cwd nil (layer 1 never
    /// records a cwd — see ``LeftoverProcessDisposition``).
    func recordLeftover(
        _ leftover: LeftoverProcess, attemptID: Int64, pass: RunPass, disposition: LeftoverProcessDisposition,
        cwd: String? = nil
    ) throws {
        try journal.append(
            .leftoverProcessRecorded(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, pass: pass, pid: leftover.pid,
                commandName: leftover.commandName, disposition: disposition, cwd: cwd
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }

    func recordFenced(
        _ process: FencedProcess, attemptID: Int64, pass: RunPass
    ) throws {
        try journal.append(
            .leftoverProcessRecorded(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, pass: pass, pid: process.pid,
                commandName: process.commandName, disposition: .sweptByWorktreeFence, cwd: nil
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }

    func recordUnattributed(
        _ process: UnattributedProcess, attemptID: Int64, pass: RunPass
    ) throws {
        try journal.append(
            .leftoverProcessRecorded(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, pass: pass, pid: process.pid,
                commandName: process.commandName, disposition: .leftRunningUnattributed, cwd: process.cwd
            ),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }
}

extension CardRun {
    /// Records every layer-1 leftover the report itself carries, then — only when the report actually
    /// spawned an agent CLI process and captured a running snapshot — runs the attributed Worktree
    /// fence against it (layer 2) and records what it killed or left unattributed. Throws
    /// ``CardRunError/worktreeNotQuiescentAfterRun(path:remaining:)`` when an attributed process is
    /// still holding the Worktree after the fence's quiescence timeout — after recording what was
    /// found, never before. A missing Worktree path is recorded (layer 1 only) and left for the next
    /// step to fault on its own; it is not this seam's error to raise.
    func sweepLeftovers(
        report: AgentDispatchReport, attemptID: Int64, pass: RunPass, worktreePath: String, frame: CardRunFrame
    ) async throws {
        for leftover in report.leftovers {
            try frame.recordLeftover(leftover, attemptID: attemptID, pass: pass, disposition: .sweptByRunningSnapshot)
        }
        guard report.origin == .agentCLIProcess, let snapshot = report.snapshot else { return }

        switch await normalExitFencing.fence(worktreePath: worktreePath, attributedTo: snapshot) {
        case .quiescent(let killed, let unattributed):
            try Self.recordFenceOutcome(
                killed: killed, unattributed: unattributed, attemptID: attemptID, pass: pass, frame: frame
            )
        case .notQuiescent(let killed, let remaining, let unattributed):
            try Self.recordFenceOutcome(
                killed: killed, unattributed: unattributed, attemptID: attemptID, pass: pass, frame: frame
            )
            throw CardRunError.worktreeNotQuiescentAfterRun(path: worktreePath, remaining: remaining.count)
        case .pathMissing:
            break
        }
    }

    private static func recordFenceOutcome(
        killed: [FencedProcess], unattributed: [UnattributedProcess], attemptID: Int64, pass: RunPass,
        frame: CardRunFrame
    ) throws {
        for process in killed {
            try frame.recordFenced(process, attemptID: attemptID, pass: pass)
        }
        for process in unattributed {
            try frame.recordUnattributed(process, attemptID: attemptID, pass: pass)
        }
    }
}
