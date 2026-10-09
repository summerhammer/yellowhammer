import Domain
import Foundation
import Journal

/// How one delivery pass rides out a board that cannot be reached: the same entry is re-sent a bounded
/// number of times, after a backoff, before it is left pending for a later Act. Without it one HTTP 503
/// on the write that closes a Night leaves the board stale until the next Night.
///
/// The resends belong to the Outbox, not the adapter: whether to send a write again is a decision, and
/// an adapter only translates (ADR-001).
public struct OutboxTransientRetry: Sendable {
    /// The wait before each resend, in order. Its count is how many resends one pass makes of an entry.
    public var backoff: [Duration]
    /// The longest single wait, a `Retry-After` included. A board that asks for longer is honoured by not
    /// resending in this pass at all: the entry is left pending.
    public var longestWait: Duration
    /// How much of the Act Lease must remain once a wait ends. The Act Lease is not heartbeated while the
    /// Night closes, so a wait that would leave less than this ends the pass instead of sleeping.
    public var leaseMargin: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    public init(
        backoff: [Duration],
        longestWait: Duration,
        leaseMargin: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.backoff = backoff
        self.longestWait = longestWait
        self.leaseMargin = leaseMargin
        self.sleep = sleep
    }

    /// Three resends, after 2 s, 8 s and 30 s; no single wait over a minute; at least one heartbeat
    /// interval of the Act Lease left after any wait.
    public static let ruled = OutboxTransientRetry(
        backoff: [.seconds(2), .seconds(8), .seconds(30)],
        longestWait: .seconds(60),
        leaseMargin: LeasePolicy.ruled.heartbeatDuration
    )

    /// No resend within a pass: one attempt, then the entry waits for the next delivery.
    public static let never = OutboxTransientRetry(backoff: [], longestWait: .zero, leaseMargin: .zero)

    /// How long to wait before resend number `resend` (0-based) after `error`, or nil when this pass
    /// should stop resending. `leaseRemaining` is the Act Lease's time left now.
    func wait(beforeResend resend: Int, after error: BoardError, leaseRemaining: Duration) -> Duration? {
        guard resend < backoff.count else { return nil }
        var wait = backoff[resend]
        if case .unreachable(_, let retryAfter?) = error {
            wait = max(wait, retryAfter)
        }
        guard wait <= longestWait, wait + leaseMargin <= leaseRemaining else { return nil }
        return wait
    }
}

/// A board call that failed in a way a resend may fix, carried out of one try to the retry loop.
struct TransientBoardFailure: Error {
    let error: BoardError
    let write: BoardWrite
}

extension Outbox {
    /// One entry, re-sent within this pass while the board cannot be reached (see
    /// ``OutboxTransientRetry``). Every resend is a whole new try — Lease revalidation, the removed and
    /// archived pre-flights, and for a description the fresh read the fenced rewrite is made from — so a
    /// stale body is never replayed over a human edit. The failed tries count as one attempt toward
    /// ``attemptLimit``, recorded only when the pass gives up, so one bad minute never exhausts a write.
    ///
    /// The delivery gate is held throughout, so a Repo Lane posting meanwhile waits for the resends.
    func deliver(_ entry: OutboxEntry) async throws -> OutboxDelivery {
        var resend = 0
        while true {
            do {
                return try await deliverOnce(entry)
            } catch let failure as TransientBoardFailure {
                guard let wait = try transientWait(beforeResend: resend, after: failure.error) else {
                    return try refused(entry, write: failure.write, error: failure.error)
                }
                try await transientRetry.sleep(wait)
                resend += 1
            }
        }
    }

    private func transientWait(beforeResend resend: Int, after error: BoardError) throws -> Duration? {
        let now = clock()
        let lease: ActLease
        do {
            lease = try journal.revalidateActLease(runID: runID, now: now)
        } catch let error as JournalError {
            guard case .actLeaseLost = error else { throw error }
            throw OutboxError.staleRun(error)
        }
        let remaining = Duration.seconds(lease.expiresAt.timeIntervalSince(now))
        return transientRetry.wait(beforeResend: resend, after: error, leaseRemaining: remaining)
    }
}
