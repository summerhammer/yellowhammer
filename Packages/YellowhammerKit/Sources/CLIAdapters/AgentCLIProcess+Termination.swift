import Darwin
import Domain
import Foundation

/// The termination sweep `AgentCLIProcess.wait(pid:timeout:)` falls into on timeout or engine
/// abort. Split out from `AgentCLIProcess.swift` because containing an escaped tool subprocess
/// (see ``ProcessTree``) needs real logic, not just a group signal.
extension AgentCLIProcess {
    /// SIGTERMs the group and every descendant snapshotted (by ``ProcessTree``) just before that
    /// first signal — snapshotting first matters because some CLIs (codex) exit on SIGTERM
    /// immediately, and once the leader is reaped its exited children fall out of the process
    /// tree and could never be found again. Then waits up to `gracePeriod` for the leader, the
    /// group, and every tracked descendant to be gone, re-walking on every poll for descendants a
    /// tool spawns mid-grace and SIGTERMing those too. Escalates to SIGKILL against the group and
    /// every tracked survivor, reaps the leader if it has not been already, and polls briefly for
    /// everything to vanish. The leader is reaped exactly once on every path — no zombies.
    func terminate(pid: pid_t, reason: TerminationReason) async -> RunEnd {
        var tracked = Set(ProcessTree.descendants(of: pid))
        ProcessGroup.signal(group: pid, SIGTERM)
        Self.signal(tracked, SIGTERM)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        var reaped = false

        while clock.now < deadline {
            reaped = reaped || ProcessGroup.reapNonBlocking(pid: pid) != nil
            Self.sweepForNewDescendants(leaderPID: pid, leaderReaped: reaped, tracked: &tracked)
            if Self.allGone(leaderPID: pid, leaderReaped: reaped, tracked: tracked) {
                return end(for: reason, forcedKill: false)
            }
            await Self.sleepThroughCancellation(for: pollInterval)
        }

        reaped = reaped || ProcessGroup.reapNonBlocking(pid: pid) != nil
        if Self.allGone(leaderPID: pid, leaderReaped: reaped, tracked: tracked) {
            return end(for: reason, forcedKill: false)
        }

        // One last walk: the loop sleeps after its final sweep, so a descendant spawned during that
        // last poll interval (or, with a zero grace period, since the snapshot) is not tracked yet.
        Self.sweepForNewDescendants(leaderPID: pid, leaderReaped: reaped, tracked: &tracked)
        ProcessGroup.signal(group: pid, SIGKILL)
        Self.signal(tracked.filter { !ProcessTree.isGone($0) }, SIGKILL)
        if !reaped {
            ProcessGroup.reapBlocking(pid: pid)
            reaped = true
        }

        let killDeadline = clock.now.advanced(by: .seconds(1))
        while clock.now < killDeadline, !Self.allGone(leaderPID: pid, leaderReaped: reaped, tracked: tracked) {
            await Self.sleepThroughCancellation(for: pollInterval)
        }

        return end(for: reason, forcedKill: true)
    }

    /// Sends `signal` to every process in `processes`, by pid identity (``ProcessTree/signal``),
    /// never by process group — a tracked descendant may already have moved to a group of its
    /// own, which is exactly why it is tracked individually.
    private static func signal(_ processes: some Sequence<ProcessTree.TrackedProcess>, _ signal: Int32) {
        for process in processes {
            ProcessTree.signal(process, signal)
        }
    }

    /// Walks from the leader — only while it has not yet been reaped, since a reaped pid can be
    /// recycled for an unrelated process — and from every still-live tracked descendant, folding
    /// in any pid not already known and SIGTERMing it at once. This is what catches a tool that
    /// spawns a fresh escaped child from inside its own SIGTERM handler: it is not in `tracked`
    /// yet when the first signal goes out, but the very next poll walks it down.
    private static func sweepForNewDescendants(
        leaderPID: pid_t, leaderReaped: Bool, tracked: inout Set<ProcessTree.TrackedProcess>
    ) {
        var roots: [pid_t] = leaderReaped ? [] : [leaderPID]
        roots.append(contentsOf: tracked.filter { !ProcessTree.isGone($0) }.map(\.pid))

        for root in roots {
            for candidate in ProcessTree.descendants(of: root) where !tracked.contains(candidate) {
                tracked.insert(candidate)
                ProcessTree.signal(candidate, SIGTERM)
            }
        }
    }

    /// The whole tree is gone: the leader has been reaped, its process group holds nothing, and
    /// every tracked descendant's identity no longer matches (exited, or its pid recycled).
    private static func allGone(
        leaderPID: pid_t, leaderReaped: Bool, tracked: Set<ProcessTree.TrackedProcess>
    ) -> Bool {
        leaderReaped && !ProcessGroup.isAlive(group: leaderPID) && tracked.allSatisfy(ProcessTree.isGone)
    }

    /// Sleeps for the whole of `duration` even when the calling task is cancelled. The abort path
    /// runs *because* the dispatch task was cancelled, and there `Task.sleep` throws at once, which
    /// would turn the grace and kill polls into a busy spin. An unstructured `Task` does not inherit
    /// the caller's cancellation, so awaiting it waits out the full duration.
    static func sleepThroughCancellation(for duration: Duration) async {
        await Task { try? await Task.sleep(for: duration) }.value
    }

    private func end(for reason: TerminationReason, forcedKill: Bool) -> RunEnd {
        switch reason {
        case .timedOut(let after):
            .timedOut(after: after, forcedKill: forcedKill)
        case .aborted:
            .aborted(forcedKill: forcedKill)
        }
    }
}
