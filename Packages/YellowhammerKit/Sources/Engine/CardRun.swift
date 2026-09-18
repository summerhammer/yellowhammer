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
///
/// Architect, worker and reviewer are internals of this run, not actors. The review's Round loop, blocking
/// a Card whose budgets are spent, and the Attempt budget are later roadmap items (P8.6, P8.7).
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

    public init(
        resolver: RouteResolver,
        dispatch: any AgentDispatch,
        check: any RepositoryCheckRunning,
        checks: [String: Check],
        reviewRoundsMax: Int,
        leasePolicy: LeasePolicy = .ruled
    ) {
        self.resolver = resolver
        self.dispatch = dispatch
        self.check = check
        self.checks = checks
        self.reviewRoundsMax = reviewRoundsMax
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

    /// Everything after the Lease is held.
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
        let outcome = try await routing.route(
            card: card, repoRole: frame.repository?.role, override: override, checkDeclaredNone: checkDeclaredNone
        )
        guard case .attempt(let attempt, let resolved) = outcome else {
            return
        }
        frame.attempt = attempt
        frame.route = resolved.route
        try frame.record(.attemptStarted, detail: "attempt \(attempt.id) on \(resolved.route)")

        try await frame.transition(.inProgress)
        let end = try await runPasses(frame: frame)
        try await conclude(end, frame: frame)
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
