import Darwin
import Domain
import Journal
import Synchronization

/// A rehearsal-only kill switch for `Outbox` replay (P15.3): the spec's rehearsal-assertable list
/// includes "Outbox idempotency, and replay after a killed run", but no external process runs between
/// the board applying a write and the Journal recording it, so a harness cannot kill a run there from
/// outside. `Outbox`'s internal `interrupt` hook runs at exactly that point; this type answers it by
/// killing this process's own run with `SIGKILL` once the n-th matching entry has been applied — the
/// instant a crash would lose the record — and never otherwise.
///
/// Parsed from a spec string: `<n>` counts every entry this run applies, of any kind; `group:<n>`
/// counts only entries that belong to an Outbox group (``OutboxEntry/groupID`` non-nil). `n` is
/// 1-based. Counting is thread-safe: the build Act's Repo Lanes can deliver concurrently.
public final class RehearsalOutboxKill: Sendable {
    private enum Scope: Sendable, Equatable {
        case any
        case group
    }

    private let target: Int
    private let scope: Scope
    private let count = Mutex(0)
    private let kill: @Sendable () -> Void

    /// `kill` is injectable so a test can observe the switch firing without actually killing the test
    /// process; it defaults to a real `SIGKILL` of this process.
    public init?(spec: String, kill: @escaping @Sendable () -> Void = RehearsalOutboxKill.realKill) {
        let scope: Scope
        let numberPart: Substring
        if spec.hasPrefix("group:") {
            scope = .group
            numberPart = spec.dropFirst("group:".count)
        } else {
            scope = .any
            numberPart = Substring(spec)
        }
        guard let ordinal = Int(numberPart), ordinal >= 1 else { return nil }
        self.target = ordinal
        self.scope = scope
        self.kill = kill
    }

    /// Counts `entry` when it is in this switch's scope, and kills the process the instant the count
    /// reaches the target — after the board applied `entry`'s write, before the Journal records it.
    func interrupt(_ entry: OutboxEntry) {
        if scope == .group, entry.groupID == nil { return }
        let fires = count.withLock { current in
            current += 1
            return current == target
        }
        if fires { kill() }
    }

    public static func realKill() {
        _ = Darwin.kill(getpid(), SIGKILL)
    }
}
