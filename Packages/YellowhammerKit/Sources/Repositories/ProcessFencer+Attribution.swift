import Darwin
import Domain
import Foundation

/// One process this run's attributed fence killed.
public struct FencedProcess: Equatable, Sendable {
    public let pid: pid_t
    public let commandName: String

    public init(pid: pid_t, commandName: String) {
        self.pid = pid
        self.commandName = commandName
    }
}

/// One holder of the Worktree the fence found but could not attribute to the run — left running.
public struct UnattributedProcess: Equatable, Sendable {
    public let pid: pid_t
    public let commandName: String
    public let cwd: String?

    public init(pid: pid_t, commandName: String, cwd: String?) {
        self.pid = pid
        self.commandName = commandName
        self.cwd = cwd
    }
}

/// The outcome of fencing a Worktree against one run's running snapshot (Normal-Exit Sweep
/// Ruling): only a holder attributed to that run is killed; a holder that cannot be attributed is
/// recorded and left running.
public enum AttributedFencingOutcome: Equatable, Sendable {
    case quiescent(killed: [FencedProcess], unattributed: [UnattributedProcess])
    case notQuiescent(killed: [FencedProcess], remaining: [FencedProcess], unattributed: [UnattributedProcess])
    case pathMissing(String)
}

extension ProcessFencer {
    /// Sweeps `worktreePath` for holders and kills only the ones attributed to `snapshot`'s run
    /// (see ``ProcessIdentity/isAttributed(pid:to:)``), by `SIGKILL` — no SIGTERM stage, because an
    /// attributed process here is already known to be this run's own leftover, not a cooperative
    /// process to be given a chance to exit cleanly. Quiescence on this path means no *attributed*
    /// holder remains; an unattributed holder never blocks it. Polls the same way
    /// ``fence(worktreePath:)`` does, re-evaluating attribution on every sweep so a newly attributed
    /// holder appearing mid-wait is caught and killed too.
    public func fence(worktreePath: String, attributedTo snapshot: RunningSnapshot) async -> AttributedFencingOutcome {
        let resolvedWorktreePath = Self.resolvedForAttribution(worktreePath)
        guard FileManager.default.fileExists(atPath: resolvedWorktreePath) else {
            return .pathMissing(resolvedWorktreePath)
        }

        var killed = Killed()
        var sweep = killed.sweepAndKill(fencer: self, worktreePath: resolvedWorktreePath, snapshot: snapshot)
        if sweep.attributedRemaining.isEmpty {
            return .quiescent(killed: killed.all, unattributed: sweep.unattributed)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: quiescenceTimeout)
        while clock.now < deadline {
            let pollInterval = pollInterval
            await Task { try? await Task.sleep(for: pollInterval) }.value
            sweep = killed.sweepAndKill(fencer: self, worktreePath: resolvedWorktreePath, snapshot: snapshot)
            if sweep.attributedRemaining.isEmpty {
                return .quiescent(killed: killed.all, unattributed: sweep.unattributed)
            }
        }

        sweep = killed.sweepAndKill(fencer: self, worktreePath: resolvedWorktreePath, snapshot: snapshot)
        guard sweep.attributedRemaining.isEmpty else {
            return .notQuiescent(
                killed: killed.all.sorted { $0.pid < $1.pid },
                remaining: sweep.attributedRemaining.sorted { $0.pid < $1.pid },
                unattributed: sweep.unattributed.sorted { $0.pid < $1.pid }
            )
        }
        return .quiescent(
            killed: killed.all.sorted { $0.pid < $1.pid }, unattributed: sweep.unattributed.sorted { $0.pid < $1.pid }
        )
    }

    /// Accumulates the processes killed across sweeps, deduplicated by pid.
    private struct Killed {
        private(set) var all: [FencedProcess] = []
        private var pids = Set<pid_t>()

        /// One sweep of the process table: kills every newly-attributed holder found (re-checking
        /// identity immediately before signalling, so a recycled pid is never hit), folds it into
        /// `all`, and reports every attributed holder still present plus every unattributed one.
        mutating func sweepAndKill(
            fencer: ProcessFencer, worktreePath: String, snapshot: RunningSnapshot
        ) -> (attributedRemaining: [FencedProcess], unattributed: [UnattributedProcess]) {
            fencer.didSweep()
            var seen = Set<pid_t>()
            var attributedRemaining: [FencedProcess] = []
            var unattributed: [UnattributedProcess] = []

            for holder in fencer.holders(of: worktreePath) where !seen.contains(holder.pid) {
                seen.insert(holder.pid)
                // Re-check identity right before deciding, so a recycled pid is never signalled.
                guard let identity = ProcessIdentity.identity(of: holder.pid),
                    ProcessIdentity.isAttributed(pid: holder.pid, to: snapshot)
                else {
                    let identity = ProcessIdentity.identity(of: holder.pid)
                    unattributed.append(UnattributedProcess(
                        pid: holder.pid, commandName: identity?.commandName ?? "", cwd: Self.cwd(of: holder)
                    ))
                    continue
                }
                if !pids.contains(holder.pid) {
                    _ = fencer.sendSignal(holder.pid, SIGKILL)
                    pids.insert(holder.pid)
                    all.append(FencedProcess(pid: holder.pid, commandName: identity.commandName))
                }
                attributedRemaining.append(FencedProcess(pid: holder.pid, commandName: identity.commandName))
            }
            return (attributedRemaining, unattributed)
        }

        /// `WorktreeHolder`'s cwd when its reason is `.workingDirectory`; `nil` for an `.openFile`
        /// holder — `WorktreeHolder` does not carry a separate cwd lookup for that case, and the
        /// brief allows `nil` here.
        private static func cwd(of holder: WorktreeHolder) -> String? {
            if case .workingDirectory(let path) = holder.reason { return path }
            return nil
        }
    }

    /// Same resolution `ProcessFencer.resolve(_:)` performs (private to that file); duplicated
    /// here at file scope rather than widening that method's access, since `holders(of:)` already
    /// re-resolves its argument internally and this only needs it for the `pathMissing` check.
    fileprivate static func resolvedForAttribution(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(expanded, &buffer) else { return expanded }
        return String(cString: resolved)
    }
}

extension ProcessIdentity {
    /// Whether `pid` — or an ancestor of it — is attributed to `snapshot`'s run (the ruling's
    /// three-part attribution rule): the process itself matches a snapshotted process by pid and
    /// start time (rule 1); or its process group or session is one the snapshot recorded, and it
    /// started strictly after `snapshot.dispatchedAt` (rule 2); or a member of its own parent
    /// chain matches rule 1 or rule 2 (rule 3) — the ancestor need not itself be a holder.
    static func isAttributed(pid: pid_t, to snapshot: RunningSnapshot) -> Bool {
        let identities = Self.chain(from: pid)
        guard !identities.isEmpty else { return false }
        let byPIDStart = Set(snapshot.processes.map { Key(pid: $0.pid, startTime: $0.startTime) })
        return identities.contains { identity in
            Self.matchesRule1(identity, byPIDStart: byPIDStart)
                || Self.matchesRule2(identity, snapshot: snapshot)
        }
    }

    private struct Key: Hashable {
        let pid: pid_t
        let startTime: ProcessStartTime
    }

    private static func matchesRule1(_ identity: Snapshot, byPIDStart: Set<Key>) -> Bool {
        byPIDStart.contains(Key(pid: identity.pid, startTime: identity.startTime))
    }

    private static func matchesRule2(_ identity: Snapshot, snapshot: RunningSnapshot) -> Bool {
        let inRecordedGroupOrSession =
            snapshot.processGroups.contains(identity.processGroup) || snapshot.sessions.contains(identity.session)
        return inRecordedGroupOrSession && identity.startTime > snapshot.dispatchedAt
    }
}
