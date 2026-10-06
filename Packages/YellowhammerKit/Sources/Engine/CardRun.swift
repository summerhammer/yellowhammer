import Domain
import Foundation
import Journal
import Repositories

/// Runs one Card to completion (graph-execution/run-a-card, roadmap P8.4), in this order, each step
/// appended to the event log as a ``CardRunStep``:
///
/// 1. Claims the Card's Lease for this run, or skips the Card without dispatching when another run
///    holds it. The Lease is heartbeated for as long as the run lasts and revalidated before every write
///    that records an outcome; a lost Lease cancels the run and nothing is written as if it were complete.
///    A run the engine cancels (the Act Lease lost, a heartbeat failed) stops at the next Attempt boundary
///    without concluding the pass the cancellation aborted, and leaves the Card Lease to expire, so the
///    Card is reclaimable and its Attempt budget is not spent on the engine's own stop. An engine fault
///    does the same once the Card is In Progress or has an open Attempt; before that it releases the Lease.
/// 2. Resolves the Route and records the Attempt (``CardRouting``); zero candidates Block the Card, and an
///    Override that cannot resolve, whose CLI failed its Probe or whose Route fails its Route Pre-flight is
///    a Readiness Check failure reported on the Card; either way nothing is dispatched.
/// 3. Moves the Card to In Progress, then dispatches the architect, then the worker, in the lane's
///    Worktree, then runs the Check, then dispatches the reviewer.
/// 4. Ends the Attempt from what the passes yielded (see `CardRun+Outcome.swift`).
///
/// Between the worker and the reviewer the engine runs the repository's Check (P8.5). A failed Check is a
/// Round on the same Attempt: the worker is dispatched again, on the same Route and in the same Worktree,
/// carrying every Round so far, until the round budget is spent, and the reviewer never sees red code.
/// A reviewer asking for changes is a Round of the same kind (P8.6): the worker goes again with every Round
/// so far — both Lenses share the one round budget — the Check runs again before the reviewer does, and the
/// reviewer never sees red code either. Once the round budget is spent with the work still not approved,
/// the Attempt ends `rounds-exhausted`; the Card blocks only once the Attempt budget is spent too, never on
/// the round budget alone.
///
/// A hard failure, a Crashed-Unknown or a `rounds-exhausted` ending, with the Attempt budget not yet spent,
/// dispatches a fresh Attempt from the same held Lease and the same Card run (roadmap P8.7): the routing is
/// resolved again — the ended Attempt's exclusions apply, so a hard failure or `rounds-exhausted` never
/// repeats its Route, while a Crashed-Unknown may land on the same one — a new Attempt is recorded, and the
/// whole pass sequence runs again from the architect, with no worker session carried over. The Card stays
/// In Progress between Attempts; it is never bounced back through Ready to get there. Once the Attempt
/// budget is spent, the Card Blocks instead — `hard failure` after a hard failure or a Crashed-Unknown,
/// or by whichever Lens's Round was the last after `rounds-exhausted` — and an `attempts-exhausted` step
/// records the Operator-facing account of how the budget was spent.
///
/// The Operator can abort a running Attempt (app/stop-the-engine-for-a-project): the run polls the Journal for
/// the Operator's request, cancels the pass, and ends the Attempt `aborted`, which consumes no Attempt, excludes
/// no Route and Blocks the Card `operator abort` (see `CardRun+OperatorAbort.swift`).
///
/// Architect, worker and reviewer are internals of this run, not actors.
public struct CardRun: CardRunner {
    public let resolver: RouteResolver
    public let dispatch: any AgentDispatch
    public let check: any RepositoryCheckRunning
    /// Each configured repository's Check, by repository name: the Engine holds no configuration, so
    /// `EngineCommand` hands it what it needs.
    public let checks: [String: Check]
    public let leasePolicy: LeasePolicy
    /// The most Rounds one Attempt may record, both Lenses together (`review_rounds_max`). Required: the ruled
    /// default lives in `Config`, and the Engine holds no configuration.
    public let reviewRoundsMax: Int
    /// The most Attempts a Card may consume in one budget epoch (`attempts_per_card`). Required: the ruled
    /// default lives in `Config`, and the Engine holds no configuration.
    public let attemptsPerCard: Int
    /// The fence → WIP-commit → preserve → reset seam (Attempt, Block and Reset Ruling 2026-09-19,
    /// OQ60), run before every new Attempt, on every Block path and when a question puts the Card in
    /// Waiting on You (OQ106): required, with no default, so production can never forget to wire the real
    /// ``AttemptWorktreeReset`` in.
    public let resetting: any AttemptResetting
    /// The attributed Worktree fence (Normal-Exit Sweep Ruling, layer 2, issue #175), run after every
    /// pass whose report carries a running snapshot. Defaulted to the real ``AttributedWorktreeFence``
    /// and placed last: a fake ``AgentDispatch`` returns no snapshot, so a test never needs to touch
    /// this, while production can never forget to wire the real fence in by omission.
    public let normalExitFencing: any NormalExitFencing
    /// The Project's `commit_message` Message Template, rendered into the worker pass's instruction
    /// (roadmap P19.4).
    public let commitMessage: MessageTemplate
    /// The Project's `change_type`, which fills the commit message's `{type}`.
    public let changeType: ChangeType
    /// Reads the worker's reported commits for the `Yellowhammer-Card` trailer, recorded only.
    public let commitTrailers: CommitTrailerReader
    /// How often a running Attempt checks the Journal for the Operator's abort request.
    public let operatorAbortPoll: Duration
    /// Runs every Card override's Route Pre-flight before an Attempt is recorded on it (OQ126), shared by
    /// every Card this runner runs so Cards pinned to the same Route share one; nil runs none.
    public let routePreflight: RoutePreflight?

    public init(
        resolver: RouteResolver,
        dispatch: any AgentDispatch,
        check: any RepositoryCheckRunning,
        checks: [String: Check],
        reviewRoundsMax: Int,
        attemptsPerCard: Int,
        leasePolicy: LeasePolicy = .ruled,
        resetting: any AttemptResetting,
        commitMessage: MessageTemplate = .default(.commitMessage),
        changeType: ChangeType = .feat,
        commitTrailers: CommitTrailerReader = CommitTrailerReader(),
        normalExitFencing: any NormalExitFencing = AttributedWorktreeFence(),
        operatorAbortPoll: Duration = .seconds(2),
        preflighting: (any RoutePreflighting)? = nil
    ) {
        self.resolver = resolver
        self.dispatch = dispatch
        self.check = check
        self.checks = checks
        self.reviewRoundsMax = reviewRoundsMax
        self.attemptsPerCard = attemptsPerCard
        self.leasePolicy = leasePolicy
        self.resetting = resetting
        self.commitMessage = commitMessage
        self.changeType = changeType
        self.commitTrailers = commitTrailers
        self.normalExitFencing = normalExitFencing
        self.operatorAbortPoll = operatorAbortPoll
        self.routePreflight = preflighting.map(RoutePreflight.init)
    }

    public func run(
        card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness
    ) async throws {
        let journal = context.act.journal
        let runID = context.act.runID
        let policy = leasePolicy

        switch try journal.claimCardLease(cardID: card.id, runID: runID, policy: policy) {
        case .held(let holder):
            try record(.skippedLeaseHeld, card: card, context: context, detail: "held by run \(holder.runID)")
            return
        case .claimed, .reclaimed:
            break
        }
        try record(.leaseClaimed, card: card, context: context)

        do {
            try await withLeaseHeartbeat(
                every: policy.heartbeatDuration,
                beat: { try journal.heartbeatCardLease(cardID: card.id, runID: runID, policy: policy) },
                body: { try await runHeld(card: card, in: lane, context: context, readiness: readiness) }
            )
        } catch JournalError.cardLeaseLost {
            // The Card is reclaimable, and no partial state was written as if it were complete: the
            // Lease is another run's now, so this one releases nothing and leaves the Card for it.
            _ = try? record(.leaseLost, card: card, context: context)
            return
        } catch let error where Self.leavesLeaseToExpire(error) {
            // The engine stopped this run, not the Card: the Card is reclaimable, and no partial state
            // was written as if it were complete. The Lease is left to expire, never released, so the
            // next build Act's ExpiredLeaseSweep (P8.10) reclaims the Card and its open Attempt: a
            // released Lease leaves an In Progress Card no sweep and no lane would ever pick up. The
            // terminal step is best-effort, like `.leaseLost` — `journal.append` does not revalidate the
            // Act Lease, so it still works after the Act Lease is gone (OQ92).
            _ = try? record(.leaseLeftToExpire, card: card, context: context, detail: Self.engineStopCause(error))
            throw error
        } catch {
            // An engine fault (a vendor or transport error, a spawn failure, a Journal write, a Worktree
            // gone) leaves the Lease to expire once the Card is In Progress or has an open Attempt: only the
            // Expired Lease Sweep reclaims such a Card, and it skips one with no Lease row. That is what keeps
            // the Card reclaimable, with no partial state written as if it were complete (issue #173).
            if Self.releasesLeaseOnFault(card: card, journal: journal) {
                _ = try? journal.releaseCardLease(cardID: card.id, runID: runID)
            } else {
                _ = try? record(.leaseLeftToExpire, card: card, context: context, detail: Self.engineStopCause(error))
            }
            throw error
        }

        if try journal.releaseCardLease(cardID: card.id, runID: runID) {
            try record(.leaseReleased, card: card, context: context)
        }
    }

    /// Everything after the Lease is held: one Attempt after another, from the same held Lease and the
    /// same Card run, until one ends the run — success, a question (after its own reset, OQ106), or the
    /// Attempt budget spent (P8.7).
    private func runHeld(
        card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness
    ) async throws {
        let journal = context.act.journal
        var frame = try await prepare(card: card, in: lane, context: context, readiness: readiness)

        try frame.revalidateLease()
        let checkDeclaredNone = frame.check == .none
        let routing = CardRouting(
            resolver: resolver, journal: journal, projection: frame.projection, runID: context.act.runID,
            act: context.act.act, nightID: context.act.night.id, preflight: routePreflight
        )
        let override = try await frame.override()

        var movedToInProgress = false
        while true {
            // A cancelled run records no new Attempt: cancellation is the engine's (a lost Act Lease, a
            // failed heartbeat), never the Card's, and a pass dispatched now would only abort at once.
            try Task.checkCancellation()
            let outcome = try await routing.route(
                card: frame.card, repoRole: frame.repository?.role, override: override,
                checkDeclaredNone: checkDeclaredNone, attemptsPerCard: attemptsPerCard
            )
            switch outcome {
            case .attempt(let attempt, let resolved):
                frame.attempt = attempt
                frame.route = resolved.route
                try frame.record(.attemptStarted, detail: "attempt \(attempt.id) on \(resolved.route)")

                // The Card stays In Progress across a retry: only the first Attempt of the run moves it.
                if !movedToInProgress {
                    try await frame.transition(.inProgress)
                    movedToInProgress = true
                }
                let end = try await runPassesWatchingForOperatorAbort(frame: frame)
                // A pass the engine cancelled ends `.aborted`, which reads as Crashed-Unknown: concluding
                // it would consume the Attempt and retry, spending the whole budget on the engine's own
                // stop. The Attempt stays open instead, for the Expired Lease Sweep to classify.
                try Task.checkCancellation()
                switch try await conclude(end, frame: frame) {
                case .stop:
                    return
                case .retry(let endedAttempt):
                    // A new Attempt starts fresh, never as a rescue (OQ60): before dispatching it, the
                    // prior Attempt's work is preserved and the Worktree reset to known-good. A failed
                    // reset never dispatches the new Attempt: the Card returns to Ready instead.
                    switch try await attemptReset(priorAttemptID: endedAttempt.id, frame: frame) {
                    case .success(let wip):
                        frame.wipContext = wip
                        continue
                    case .failure:
                        try await frame.transition(.ready)
                        return
                    }
                }

            case .blocked(let blockedCard, _):
                // Routing already wrote the Blocked transition; the reset still runs, so a Card that
                // Blocks never leaves half-finished edits sitting in its Worktree (OQ60).
                try await attemptResetBeforeBlock(card: blockedCard, frame: frame)
                return

            case .readinessFailure(_, let refusal):
                // The refusal is reported on the Card, which is otherwise untouched: no Attempt, nothing
                // dispatched, and no Block — so no reset: nothing ran here for the reset sequence to move.
                return try await reportOverrideRefusal(refusal, frame: frame)

            case .attemptBudgetSpent(let spentCard):
                try await blockOnSpentAttemptBudget(card: spentCard, frame: frame)
                return
            }
        }
    }

    /// Whether `error` stopped the run from outside the Card — the run was cancelled, or the Act Lease
    /// is gone — so the Card Lease must be left to expire rather than released (see ``run``).
    private static func leavesLeaseToExpire(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case JournalError.actLeaseLost = error { return true }
        return false
    }

    /// The Operator-facing cause recorded alongside ``CardRunStep/leaseLeftToExpire`` (OQ92): a
    /// cancellation names itself; anything else is described as given — `JournalError.actLeaseLost`'s
    /// description already reads "Run X no longer holds the Project: ...".
    static func engineStopCause(_ error: any Error) -> String {
        if error is CancellationError { return "the run was cancelled" }
        return String(describing: error)
    }

    /// Whether an engine fault may release the Card Lease: only when the Journal shows the Card neither
    /// In Progress nor holding an open Attempt. Such a Card is reclaimed only by the Expired Lease Sweep,
    /// which skips a Card with no Lease row. A Journal that cannot say keeps the Lease: a Lease left
    /// over costs one TTL, a released one strands the Card.
    private static func releasesLeaseOnFault(card: CardRecord, journal: JournalStore) -> Bool {
        guard let current = try? journal.card(id: card.id),
            let history = try? journal.attemptHistory(cardID: card.id) else { return false }
        return current.state != .inProgress && history.openAttempt == nil
    }

    func record(_ step: CardRunStep, card: CardRecord, context: BuildActContext, detail: String? = nil) throws {
        try context.act.journal.append(
            .cardRunStep(cardID: card.id, issueID: card.issueID, step: step, detail: detail),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }
}

/// A fault of the Card run itself, not an outcome of the Card: the lane stops.
public enum CardRunError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Journal holds no Worktree for the Card's repository in this Feature.
    case worktreeMissing(featureID: Int64, repository: String)
    /// The Card's repository has no Check declared to the Card run.
    case checkUnknown(repository: String)
    /// A pass came back with a result for another pass.
    case unexpectedResult(expected: RunPass, found: RunPass)
    /// The attributed Worktree fence (Normal-Exit Sweep Ruling, layer 2, issue #175) found an
    /// attributed process still holding the Worktree after its quiescence timeout: the Check or the
    /// next pass must never start while a process this run spawned is still writing there.
    case worktreeNotQuiescentAfterRun(path: String, remaining: Int)

    public var description: String {
        switch self {
        case .worktreeMissing(let featureID, let repository):
            "Feature \(featureID) holds no Worktree for repository '\(repository)'"
        case .checkUnknown(let repository):
            "repository '\(repository)' has no Check declared to the Card run"
        case .unexpectedResult(let expected, let found):
            "the \(expected.rawValue) pass returned a \(found.rawValue) result"
        case .worktreeNotQuiescentAfterRun(let path, let remaining):
            "Worktree '\(path)' still holds \(remaining) attributed process(es) after the run"
        }
    }
}
