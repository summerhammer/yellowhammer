import Domain
import Foundation
import Journal

/// Replays a Card state write a Card-running Act deferred and left behind, for an Act that runs no Card
/// of its own (issue #96; spec: board-projection/write-board-updates-through-the-outbox — "a
/// write accepted before the crash is either completed or safely re-attempted after it").
///
/// ``BuildAct`` reposts deferred Card state at the top of its own run, through
/// ``BoardStateProjection/repost()``, and that stays the only repost it needs (it precedes the Delta
/// Read, and it runs after ``ExpiredLeaseSweep`` has already classified any crashed Attempt, so it is
/// entitled to reclaim an expired Card Lease). But `BuildAct` returns idle the moment no Feature is in
/// flight or the in-flight Cycle already landed — exactly the state a Feature merge closure
/// (``FeatureMergeClosure``, P10.8) or the settle gesture's release (P10.9) leaves behind, and both of
/// those run inside the author Act, which dispatches no Card and so never calls `repost()`. The land Act
/// dispatches no Card either. Both call ``Outbox/deliverPending()`` in their write-back, but that only
/// retries entries this run already holds the Card Lease for; a Card state write ``CardAutoBlock`` deferred
/// (rate limit, transient outage) is left `cardLeaseNotHeld` forever, because the Lease was released the
/// moment the write was accepted, the same claim → write → release pattern every seam here uses. Nothing
/// else ever retries it. This type is that "nothing else": run from the author and land Acts' own
/// write-back, just before their `deliverPending()`.
enum DeferredCardStateReplay {
    /// Replays every unposted Card state write this Project's Journal knows about, at zero cost when
    /// there is nothing to replay: no Outbox or Board bound, or no unposted Card, makes no board call and
    /// appends no event.
    static func run(context: ActContext) async throws {
        guard let outbox = context.outbox, let board = context.board else { return }

        // `cardsWithUnpostedState()` leaves out a freshly authored Card (state_version 0): its authoring
        // group created it on the board in Todo (``AuthoringTransaction+Plan``), so it has no deferred
        // write of its own.
        let cards = try context.journal.cardsWithUnpostedState()
        guard !cards.isEmpty else { return }

        let scope: BoardStateScope
        do {
            scope = try await BoardStateScope.resolve(using: board.provisioning)
        } catch BoardError.rateLimited(let retryAfter, _) {
            var reason = "the deferred Card state replay was refused for the rate budget; "
                + "the board's own workflow states could not be resolved, so \(cards.count) Card(s) stay "
                + "pending for a later Act"
            if let retryAfter {
                reason += "; retry after \(retryAfter)"
            }
            try context.journal.append(
                .rateBudgetExhausted(degradation: reason, installation: board.installation),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return
        } catch BoardError.unreachable, BoardError.unreadableResponse {
            // Transient: the Cards stay pending for a later Act, exactly as an Outbox deferral would.
            return
        }

        let projection = BoardStateProjection(journal: context.journal, outbox: outbox, scope: scope)
        // Never reclaims another run's expired Card Lease (P8.10's `ExpiredLeaseSweep` reads that row to
        // classify the crashed Attempt); a Card another run holds, live or expired, is skipped and stays
        // pending.
        let outcomes = try await projection.repost(cards, reclaimingExpiredLeases: false)

        let posted = outcomes.filter {
            switch $0 {
            case .posted: true
            case .unchanged, .deferred, .failed: false
            }
        }.count
        try context.journal.append(
            .boardStateReposted(cards: posted), act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
