import Domain
import Foundation
import Journal

/// What the predecessor-ancestry gate (P9.2) found for the Feature about to be authored.
public enum PredecessorGateOutcome: Equatable, Sendable {
    /// The predecessor Feature has landed in every one of this Project's repositories — or there is
    /// no predecessor to check.
    case landed
    /// The predecessor Feature has not landed in one or more repositories: authoring must not proceed.
    case notLanded(predecessorIssueID: String, repositories: [String])
    /// The predecessor Feature's Feature Branch could not be found in one or more repositories that
    /// have no recorded landing either (roadmap P9.9): authoring must not proceed, but this is not the
    /// same as a known unmerged branch — takes precedence over ``notLanded`` when any repository is
    /// indeterminate.
    case indeterminate(predecessorIssueID: String, repositories: [String])
}

/// Checks whether the Feature about to be authored may proceed, given its predecessor's ancestry
/// (feature-authoring/select-the-next-feature, risks.md OQ13). The real gate is P9.2; this is the
/// injectable seam the author Act runs strictly before selecting or authoring anything.
public protocol PredecessorGate: Sendable {
    func check(_ context: ActContext) async throws -> PredecessorGateOutcome
}

/// What selecting and authoring a Feature found.
public enum FeatureAuthoringOutcome: Equatable, Sendable {
    /// A Feature was selected and authored.
    case authored
    /// Nothing was selectable to author.
    case noWorkAvailable
    /// A Feature was selected but authoring halted before any dispatch — no backward-compatible seam,
    /// undetermined repositories, a repository outside this Project or an unreadable contract (roadmap
    /// P9.3, P9.6; spec: feature-authoring/select-the-next-feature, second and fourth stories). A quiet Night, not a
    /// failure: recorded and routed to Waiting on You by ``FeatureSelection`` itself, before this
    /// outcome is even returned.
    case halted
    /// A Feature was selected but its specification was too thin to cite a Definition of Done (roadmap
    /// P9.5, P9.8; glossary: Refusal). Not a halt: recorded and routed to Waiting on You by
    /// ``RefusalRecording``. A quiet Night for this Act.
    case refused
    /// Authoring was attempted and the whole transaction was rolled back (roadmap P9.4, P9.10): no
    /// Feature Issue, Card, Cycle or row was left behind, and the fault is recorded on the Night Card.
    /// Covers both a board rollback of an accepted group and a breakdown `FeatureBreakdownValidation`
    /// rejected before anything was ever accepted into the Outbox — an authoring fault, not a halt: it
    /// touches no Authoring Halt row and no Refusal. Like a halt, the Act itself still ends normally — a
    /// quiet Night for this Act — and the next author Act authors afresh.
    case authoringRolledBack
    /// Authoring was accepted but not yet fully delivered — the board's rate limit, a transient outage or
    /// a lost Card Lease deferred it. Nothing is written to the Journal's Feature, Cycle or Card rows
    /// until the whole group is on the board; a later author Act resumes it without selecting again.
    case authoringPending
}

/// Selects and authors the next Feature (P9.3–P9.7). The real implementation is a later phase; this
/// is the injectable seam the author Act calls once the predecessor gate has cleared.
public protocol FeatureAuthoring: Sendable {
    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome
}

/// The author Act's work (roadmap P9.1; spec: feature-authoring/select-the-next-feature, risks.md
/// OQ13), in this order:
///
/// 1. The Night Card is opened before any work — done by ``EngineInvocation/runUnderLease()``, before
///    this Act's work ever runs.
/// 2. If a Feature is already in flight for this Project (``JournalStore/inFlightFeature()`` non-nil —
///    an open Cycle, which covers a Feature returned, Blocked, or half-triaged) authoring stops here:
///    never more than one Feature in flight per Project, even when the trigger is forced or names a
///    Feature (``ActTrigger/forcedForFeature``).
/// 3. The predecessor-ancestry gate (``predecessorGate``, P9.2) runs. A predecessor not yet landed in
///    every repository stops authoring: no Worktree is allocated, nothing is dispatched, no Attempt
///    is recorded.
/// 4. Selecting and authoring the Feature (``authoring``, P9.3–P9.7) runs only once the gate clears.
///    A halt (``FeatureAuthoringOutcome/halted``), a rolled-back transaction
///    (``FeatureAuthoringOutcome/authoringRolledBack``) and an accepted-but-undelivered one
///    (``FeatureAuthoringOutcome/authoringPending``) are treated the same as a successful authoring:
///    each has already recorded itself, so this Act only falls through to write-back.
/// 5. Nothing selectable to author records the Night's idle verdict
///    (``JournalStore/recordAuthoringNoWorkAvailable(nightID:act:runID:)``).
///
/// Before any of the above, the Refusal clock advances (``UnansweredPositionClock``, P9.7) and this Act
/// reads and banks replies to Cards left Waiting on You in an already-landed Cycle
/// (``PostLandingReplies``, roadmap P11.3) — the only place that ever happens once no build Act fires
/// for that Cycle again.
///
/// Each of steps 2, 3 and 5 (and a halt inside step 4) is a quiet Night, not a failure: the Act returns
/// normally (the invocation records `ActEnded`) and the reason is put on the Night Card right away,
/// before the Act's own write-back. This Act dispatches no Card, so its write-back also runs
/// ``DeferredCardStateReplay`` (issue #96) before delivering pending Outbox entries: a Card
/// state write a merge closure (P10.8) or a settle release (P10.9) deferred is otherwise never retried,
/// because those seams release the Card Lease the instant the deferred write is accepted.
public struct AuthorAct: Sendable {
    /// The predecessor-ancestry gate (P9.2); nil is treated as `.landed` — there is no gate to fail
    /// yet, so authoring is never blocked on a check that has not landed.
    public let predecessorGate: (any PredecessorGate)?
    /// Selects and authors the next Feature (P9.3–P9.7); nil keeps this Act's public behaviour of
    /// throwing `notImplemented` once the gate has cleared, so production never falsely records an
    /// idle verdict before selection exists.
    public let authoring: (any FeatureAuthoring)?
    /// The Operator's settle gesture (roadmap P10.9); nil skips the settle read entirely.
    public let settle: (any FeatureSettle)?
    /// The Refusal clock's bound (bounds/bound-unanswered-nights): how many Nights a Refusal may go
    /// unanswered before it expires. Defaults to the glossary's own default of 3.
    public let unansweredNightsMax: Int

    public init(
        predecessorGate: (any PredecessorGate)? = nil, authoring: (any FeatureAuthoring)? = nil,
        settle: (any FeatureSettle)? = nil, unansweredNightsMax: Int = 3
    ) {
        self.predecessorGate = predecessorGate
        self.authoring = authoring
        self.settle = settle
        self.unansweredNightsMax = unansweredNightsMax
    }

    public var work: EngineInvocation.ActWork {
        { context in try await self.run(context) }
    }

    public func run(_ context: ActContext) async throws {
        let journal = context.journal

        // Every open Refusal's clock advances on every author Act of every Night, before anything
        // else this Act does (roadmap P9.7) — including the in-flight check below, since a Refusal
        // precedes any Cycle and so is never itself the reason a Feature is in flight.
        try await UnansweredPositionClock.run(context: context, unansweredNightsMax: unansweredNightsMax)

        // Once a Feature has landed, no build Act ever fires again (P10.1) and so nothing else reads
        // the board for a Card left Waiting on You — the author Act reads and banks its replies itself
        // (roadmap P11.3), and then spends the unanswered-Nights clock for those same Cards (roadmap
        // P11.4), strictly before the predecessor gate below, whose merge closure auto-Blocks a Waiting
        // on You Card and would otherwise carry an unbanked reply, or an unspent Night, forward as lost.
        try await runPostLandingRepliesAndClock(context: context)

        // The predecessor-ancestry gate's pass (P9.9) runs every Night, independently of the in-flight
        // skip below: it observes the in-flight Feature's landings when one is open (so they accumulate
        // before it becomes tomorrow's predecessor) and gates the predecessor when nothing is. It opens
        // no lane, consumes no Attempt, writes nothing to the board. The gate's own closure seam may
        // close the in-flight Feature by merge (P10.8) — merge wins over a same-morning release.
        var gateOutcome = try await checkPredecessorGate(context: context)

        // The Operator's settle gesture (P10.9) applies to whatever Feature is still in flight after
        // the gate's own merge closure. If it released the Feature, the Feature is no longer in flight
        // (its Cycle is archived), so the gate is re-run: the walk skips a released Feature
        // (JournalStore+Predecessor.swift), and this same Act goes on to decide whether authoring
        // proceeds against the new predecessor.
        if let (feature, cycleID) = try journal.inFlightFeature(), let settle {
            try await settle.settle(feature: feature, cycleID: cycleID, context: context)
            if try journal.inFlightFeature() == nil {
                gateOutcome = try await checkPredecessorGate(context: context)
            }
        }

        if let (feature, _) = try journal.inFlightFeature() {
            try journal.append(
                .authoringSkippedFeatureInFlight(featureIssueID: feature.issueID),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await writeBack(context: context)
            return
        }

        switch gateOutcome {
        case .notLanded(let predecessorIssueID, let repositories):
            try journal.append(
                .authoringPredecessorNotLanded(featureIssueID: predecessorIssueID, repositories: repositories),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await writeBack(context: context)
            return
        case .indeterminate(let predecessorIssueID, let repositories):
            try journal.append(
                .authoringPredecessorIndeterminate(featureIssueID: predecessorIssueID, repositories: repositories),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await writeBack(context: context)
            return
        case .landed:
            break
        }

        guard let authoring else {
            throw EngineInvocationError.notImplemented(.author)
        }

        switch try await authoring.selectAndAuthor(context) {
        case .noWorkAvailable:
            try journal.recordAuthoringNoWorkAvailable(
                nightID: context.night.id, act: context.act, runID: context.runID
            )
        case .authored, .halted, .refused, .authoringRolledBack, .authoringPending:
            break
        }
        try await writeBack(context: context)
    }

    private func checkPredecessorGate(context: ActContext) async throws -> PredecessorGateOutcome {
        guard let predecessorGate else { return .landed }
        return try await predecessorGate.check(context)
    }

    /// Reads and banks replies to Cards left Waiting on You after their Feature has landed
    /// (``PostLandingReplies``, roadmap P11.3), then spends the unanswered-Nights clock for those same
    /// Cards (``UnansweredCardClock``, roadmap P11.4) — skipped only when the read degraded, since an
    /// unread answer must never be charged as silence, but spent when no Board is bound at all, exactly
    /// like the Refusal clock. Split out of ``run(_:)`` to keep that function within the length limit.
    private func runPostLandingRepliesAndClock(context: ActContext) async throws {
        let postLandingOutcome = try await PostLandingReplies.run(
            context: context, unansweredNightsMax: unansweredNightsMax
        )
        guard postLandingOutcome != .degraded else { return }
        let landedCycleIDs = try context.journal.landedCycleIDsWithWaitingOnYouCards()
        try await UnansweredCardClock.run(
            cycleIDs: landedCycleIDs, unansweredNightsMax: unansweredNightsMax, context: context
        )
    }

    /// Puts a quiet reason (or the idle verdict) on the Night Card right away, replays any Card state
    /// write a merge closure or the settle gesture's release deferred (``DeferredCardStateReplay``,
    /// issue #96 — this Act dispatches no Card, so nothing else ever retries one), then delivers
    /// pending Outbox entries. A deferred or failed delivery must not fail the Act — the Outbox (or the
    /// next Act's own replay) tries again later.
    private func writeBack(context: ActContext) async throws {
        if let nightCard = context.nightCard {
            try nightCard.recordAuthoring(night: context.night)
        }
        try await DeferredCardStateReplay.run(context: context)
        guard let outbox = context.outbox else { return }
        _ = try await outbox.deliverPending()
    }
}
