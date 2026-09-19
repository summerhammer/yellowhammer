import Domain
import Foundation
import Journal

/// Runs one Card to completion (graph-execution/run-a-card, roadmap P8.4), in this order, each step
/// appended to the event log as a ``CardRunStep``:
///
/// 1. Claims the Card's Lease for this run, or skips the Card without dispatching when another run
///    holds it. The Lease is heartbeated for as long as the run lasts and revalidated before every write
///    that records an outcome; a lost Lease cancels the run and nothing is written as if it were complete.
/// 2. Resolves the Route and records the Attempt (``CardRouting``); zero candidates Block the Card and an
///    Override that cannot resolve is a Readiness Check failure, and either way nothing is dispatched.
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

    public init(
        resolver: RouteResolver,
        dispatch: any AgentDispatch,
        check: any RepositoryCheckRunning,
        checks: [String: Check],
        reviewRoundsMax: Int,
        attemptsPerCard: Int,
        leasePolicy: LeasePolicy = .ruled
    ) {
        self.resolver = resolver
        self.dispatch = dispatch
        self.check = check
        self.checks = checks
        self.reviewRoundsMax = reviewRoundsMax
        self.attemptsPerCard = attemptsPerCard
        self.leasePolicy = leasePolicy
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
                body: { try await runHeld(card: card, context: context, readiness: readiness) }
            )
        } catch JournalError.cardLeaseLost {
            // The Card is reclaimable, and no partial state was written as if it were complete: the
            // Lease is another run's now, so this one releases nothing and leaves the Card for it.
            _ = try? record(.leaseLost, card: card, context: context)
            return
        } catch {
            _ = try? journal.releaseCardLease(cardID: card.id, runID: runID)
            throw error
        }

        if try journal.releaseCardLease(cardID: card.id, runID: runID) {
            try record(.leaseReleased, card: card, context: context)
        }
    }

    /// Everything after the Lease is held: one Attempt after another, from the same held Lease and the
    /// same Card run, until one ends the run — success, a question, or the Attempt budget spent (P8.7).
    private func runHeld(card: CardRecord, context: BuildActContext, readiness: CardReadiness) async throws {
        let journal = context.act.journal
        var frame = try await prepare(card: card, context: context, readiness: readiness)

        try frame.revalidateLease()
        let checkDeclaredNone = frame.check == .none
        let routing = CardRouting(
            resolver: resolver, journal: journal, projection: frame.projection, runID: context.act.runID,
            act: context.act.act, nightID: context.act.night.id
        )
        let override = try await frame.override()

        var movedToInProgress = false
        while true {
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
                let end = try await runPasses(frame: frame)
                switch try await conclude(end, frame: frame) {
                case .stop:
                    return
                case .retry:
                    continue
                }

            case .blocked, .readinessFailure:
                // Routing already wrote the whole consequence: Blocked with no Attempt, or the refusal to
                // report with the Card untouched. Either way nothing is dispatched.
                return

            case .attemptBudgetSpent(let spentCard):
                try await blockOnSpentAttemptBudget(card: spentCard, frame: frame)
                return
            }
        }
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

    public var description: String {
        switch self {
        case .worktreeMissing(let featureID, let repository):
            "Feature \(featureID) holds no Worktree for repository '\(repository)'"
        case .checkUnknown(let repository):
            "repository '\(repository)' has no Check declared to the Card run"
        case .unexpectedResult(let expected, let found):
            "the \(expected.rawValue) pass returned a \(found.rawValue) result"
        }
    }
}
