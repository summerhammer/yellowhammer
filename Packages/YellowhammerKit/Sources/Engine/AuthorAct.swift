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
    /// Neither the commit the land Act recorded nor the Feature Branch of the predecessor Feature could be
    /// found in one or more repositories that have no Observed Merge either (roadmap P9.9; spec:
    /// feature-authoring/select-the-next-feature, #tested-tip): authoring must not proceed, but this is not the
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
    /// A Feature was selected that touches a consumer Repo the release gate holds tonight: it reads a producer
    /// by tag, and no release of the producer contains the producer's latest Feature yet
    /// (feature-authoring/select-the-next-feature, `#release-gate`). Nothing is recorded as selected and
    /// nothing is authored. A quiet Night, not a failure.
    case releaseGateHeld
    /// A Feature was selected but its specification was too thin to cite a Definition of Done (roadmap
    /// P9.5, P9.8; glossary: Refusal). Not a halt: recorded and routed to Waiting on You by
    /// ``RefusalRecording``. A quiet Night for this Act.
    case refused
    /// Authoring was attempted and the whole transaction was rolled back (roadmap P9.4, P9.10): no
    /// Feature Issue, Card, Cycle or row was left behind, and the fault is recorded on the Night Card.
    /// Covers both a board rollback of an accepted group and a breakdown `FeatureBreakdownValidation`
    /// rejected before anything was ever accepted into the Outbox — an authoring fault, not a halt: it
    /// touches no Authoring Halt row and no Refusal. The Act still ends with `ActEnded`, but it is an Act
    /// failure, not a quiet Night: the app shows it in Health (Authoring Fault in Health Ruling,
    /// 2026-10-16). The next author Act authors afresh.
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
/// Right after that read, ``HaltedFeatureRepair`` observes each tracked halted Feature Card (roadmap P22.5): the
/// Operator's move to Todo is a pending request to resume that same Feature, answered with feedback when this Act
/// cannot act on it (steps 2 and 3), and the Card's observed state conditions the clock's Blocked write.
///
/// Before any of the above, this Act reconciles the Board (``PostLandingReplies``, roadmap P11.3, P22.3):
/// a Delta Read on every author Act, which banks replies to Cards left Waiting on You in an already-landed
/// Cycle — the only place that ever happens once no build Act fires for that Cycle again — and shelves a
/// Card the Operator cancelled before anything closes, settles or selects (issue #559). Only then do the
/// Refusal clock (``UnansweredPositionClock``, P9.7) and the unanswered-Nights clock advance. If the read
/// did not complete (rate budget, or the request cap), none of that runs, and none of steps 2–5: no clock
/// advances, and the Act only writes back what an earlier step already accepted (a deferred Card state
/// write is not replayed over a board that was not read).
///
/// Each of steps 2, 3 and 5 (and a halt inside step 4) is a quiet Night, not a failure: the Act returns
/// normally (the invocation records `ActEnded`) and the reason is put on the Night Card right away,
/// before the Act's own write-back. An authoring fault (a rolled-back transaction, a rejected breakdown,
/// a failed selection) also ends with `ActEnded`, yet is an Act failure the app shows in Health
/// (Authoring Fault in Health Ruling, 2026-10-16); only halts, release-gate holds and no-work stay quiet. This Act dispatches no Card, so its write-back also runs
/// ``DeferredCardStateReplay`` (issue #96) before delivering pending Outbox entries: a Card
/// state write a merge closure (P10.8) or a Board disposition (P10.9, P22.2) deferred is otherwise never retried,
/// because those seams release the Card Lease the instant the deferred write is accepted.
public struct AuthorAct: Sendable {
    /// The predecessor-ancestry gate (P9.2); nil is treated as `.landed` — there is no gate to fail
    /// yet, so authoring is never blocked on a check that has not landed.
    public let predecessorGate: (any PredecessorGate)?
    /// Selects and authors the next Feature (P9.3–P9.7); nil keeps this Act's public behaviour of
    /// throwing `notImplemented` once the gate has cleared, so production never falsely records an
    /// idle verdict before selection exists.
    public let authoring: (any FeatureAuthoring)?
    /// The native disposition seam (roadmap P10.9, P22.2): reads the in-flight Feature Card's workflow
    /// type and settles a Done or Cancelled one; nil skips the Board read entirely.
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

        // The Board is reconciled first (roadmap P22.3; spec: board-projection/read-board-changes-by-delta,
        // `sync-boundary`): every clock, the settle gesture, the predecessor gate and selection decide on a
        // board that was read. Once a Feature has landed, no build Act ever fires again (P10.1), so nothing
        // else reads the board for that Cycle's Cards — this read banks replies to Cards left Waiting on You
        // in it (roadmap P11.3), strictly before the predecessor gate below, whose merge closure auto-Blocks a
        // Waiting on You Card and would otherwise carry an unbanked reply, or an unspent Night, forward as
        // lost. The merge closure, the settle gesture and selection then see the Operator's Cancels (issue
        // #559). A read that did not complete decides none of them this Act: no clock advances, nothing is
        // closed, settled or selected, and the Act only writes back what was already accepted.
        guard try await reconcileBoard(context: context) != .degraded else {
            try await writeBack(context: context, boardRead: false)
            return
        }

        // An existing halted Feature the Operator repaired and moved to Todo is a pending request to validate and
        // resume, not another Night of silence (roadmap P22.5; spec: feature-authoring/select-the-next-feature,
        // `#halted-authoring-repair`): the board is observed, and each tracked halt's Feature Card state recorded as
        // the condition the clock's Blocked write is decided against, before the clock runs.
        try await HaltedFeatureRepair.observe(context: context)

        // Every open Refusal's clock advances on every author Act of every Night, before anything else this
        // Act decides (roadmap P9.7) — including the in-flight check below, since a Refusal precedes any
        // Cycle and so is never itself the reason a Feature is in flight.
        try await UnansweredPositionClock.run(context: context, unansweredNightsMax: unansweredNightsMax)
        try await spendLandedCycleClock(context: context)

        // The predecessor-ancestry gate's pass (P9.9) runs every Night, independently of the in-flight
        // skip below: it observes the in-flight Feature's landings when one is open (so they accumulate
        // before it becomes tomorrow's predecessor) and gates the predecessor when nothing is. It opens
        // no lane, consumes no Attempt, writes nothing to the board. The gate's own closure seam may
        // close the in-flight Feature by merge (P10.8) — merge wins over a same-morning Board disposition,
        // which the native-disposition seam then applies to whatever is still in flight.
        let gateOutcome = try await settleInFlightFeature(
            gateOutcome: try await checkPredecessorGate(context: context), context: context
        )

        if let (feature, _) = try journal.inFlightFeature() {
            try journal.append(
                .authoringSkippedFeatureInFlight(featureIssueID: feature.issueID),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await skipAuthoring(because: .featureInFlight, context: context)
            return
        }

        switch gateOutcome {
        case .notLanded(let predecessorIssueID, let repositories):
            try journal.append(
                .authoringPredecessorNotLanded(featureIssueID: predecessorIssueID, repositories: repositories),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await skipAuthoring(because: .predecessorNotLanded, context: context)
            return
        case .indeterminate(let predecessorIssueID, let repositories):
            try journal.append(
                .authoringPredecessorIndeterminate(featureIssueID: predecessorIssueID, repositories: repositories),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await skipAuthoring(because: .predecessorNotLanded, context: context)
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
        case .authored, .halted, .releaseGateHeld, .refused, .authoringRolledBack, .authoringPending:
            break
        }
        try await writeBack(context: context)
    }

    /// A quiet Night: authoring does not run, so a repair the Operator asked for is answered with the reason
    /// (roadmap P22.5), and the Act only writes back.
    private func skipAuthoring(
        because reason: HaltedFeatureRepair.DeferralReason, context: ActContext
    ) async throws {
        try await HaltedFeatureRepair.deferPending(reason: reason, context: context)
        try await writeBack(context: context)
    }

    /// The Feature Card's native disposition (P10.9, P22.2) applies to whatever Feature is still in
    /// flight after the gate's own merge closure. If it closed the Feature (Done or Cancelled), the
    /// Feature is no longer in flight (its Cycle is archived), so the gate is re-run: the walk skips a
    /// cancelled Feature but takes a completed one as the predecessor (JournalStore+Predecessor.swift),
    /// and this same Act goes on to decide whether authoring proceeds — or names the repositories whose
    /// merge is outstanding. Returns the gate outcome authoring decides on.
    private func settleInFlightFeature(
        gateOutcome: PredecessorGateOutcome, context: ActContext
    ) async throws -> PredecessorGateOutcome {
        guard let (feature, cycleID) = try context.journal.inFlightFeature(), let settle else { return gateOutcome }
        try await settle.settle(feature: feature, cycleID: cycleID, context: context)
        guard try context.journal.inFlightFeature() == nil else { return gateOutcome }
        return try await checkPredecessorGate(context: context)
    }

    private func checkPredecessorGate(context: ActContext) async throws -> PredecessorGateOutcome {
        guard let predecessorGate else { return .landed }
        return try await predecessorGate.check(context)
    }

    /// Reads the board (``PostLandingReplies``, roadmap P11.3, P22.3; issue #559) and banks the replies it
    /// finds. Returns what the read did, so a degraded one stops the Act. Split out of ``run(_:)`` to keep
    /// that function within the length limit.
    private func reconcileBoard(context: ActContext) async throws -> PostLandingRepliesOutcome {
        try await PostLandingReplies.run(context: context, unansweredNightsMax: unansweredNightsMax)
    }

    /// Spends the unanswered-Nights clock for the Cards left Waiting on You in a landed Cycle (roadmap
    /// P11.4): only after the board was read, since an unread answer must never be charged as silence.
    private func spendLandedCycleClock(context: ActContext) async throws {
        let landedCycleIDs = try context.journal.landedCycleIDsWithWaitingOnYouCards()
        try await UnansweredCardClock.run(
            cycleIDs: landedCycleIDs, unansweredNightsMax: unansweredNightsMax, context: context
        )
    }

    /// Puts a quiet reason (or the idle verdict) on the Night Card right away, replays any Card state
    /// write a merge closure or the settle gesture's release deferred (``DeferredCardStateReplay``,
    /// issue #96 — this Act dispatches no Card, so nothing else ever retries one), then delivers
    /// pending Outbox entries. A deferred or failed delivery must not fail the Act — the Outbox (or the
    /// next Act's own replay) tries again later. The replay of a deferred Card state write is a decision
    /// about what the board should hold, so it waits for a completed read (`boardRead`); the delivery of
    /// entries an earlier step already accepted does not.
    private func writeBack(context: ActContext, boardRead: Bool = true) async throws {
        if let nightCard = context.nightCard {
            try await nightCard.recordAuthoring(night: context.night)
        }
        if boardRead {
            try await DeferredCardStateReplay.run(context: context)
        }
        guard let outbox = context.outbox else { return }
        _ = try await outbox.deliverPending()
    }
}
