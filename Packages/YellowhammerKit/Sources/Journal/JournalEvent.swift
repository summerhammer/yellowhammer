import Domain
import Foundation

/// The fields of a `featureSelected` event, wrapped in a struct (rather than a wide enum case) to keep
/// `JournalEvent`'s cases within SwiftLint's associated-values-count limit.
public struct FeatureSelectedPayload: Equatable, Sendable {
    public let name: String
    public let reasoning: String
    /// Non-nil when the selection is one step of a sequence (feature-authoring/select-the-next-feature,
    /// second story).
    public let precededBy: String?
    public let followedBy: String?
    public let seam: String?
    public let repositories: [String]
    public let adoptedCardIssueIDs: [String]
    /// Adoption candidates this selection did not take up — the Night Summary's standing line names
    /// them later (roadmap P12), so that work no Feature covers is never merely invisible.
    public let unadoptedCardIssueIDs: [String]

    public init(
        name: String,
        reasoning: String,
        precededBy: String?,
        followedBy: String?,
        seam: String?,
        repositories: [String],
        adoptedCardIssueIDs: [String],
        unadoptedCardIssueIDs: [String]
    ) {
        self.name = name
        self.reasoning = reasoning
        self.precededBy = precededBy
        self.followedBy = followedBy
        self.seam = seam
        self.repositories = repositories
        self.adoptedCardIssueIDs = adoptedCardIssueIDs
        self.unadoptedCardIssueIDs = unadoptedCardIssueIDs
    }
}

/// One entry of the Project's append-only event log, typed so that the spec's vocabulary is the code's.
public enum JournalEvent: Equatable, Sendable {
    case actStarted
    case actEnded
    /// The Act's trigger predicate was false; it recorded an idle tick and exited normally.
    case actIdle(reason: ActIdleReason)
    /// The Act could not complete; `reason` is what it knew when it gave up.
    case actIncomplete(reason: String)
    /// Another run of the same Project held the Act-scoped lease; this Act ran nothing.
    case actStoodDown(holder: ActLease)
    case mainlineFetchFailed(repository: String, reason: String)
    /// The resumption self-audit found a Night that never opened (OQ12): a calendar date
    /// between two recorded Nights with no Night row. Recorded on the Night that resumed, by its
    /// first Act. Reported, never acted on — `unanswered_nights_max` is spent only by Nights that ran.
    case absentNightDetected(nightStart: NightStart)
    case authoringNoWorkAvailable
    /// The author Act found a Feature already in flight for this Project (an open Cycle) and authored
    /// nothing: never more than one Feature in flight per Project, even forced. A quiet Night, not a failure.
    case authoringSkippedFeatureInFlight(featureIssueID: String)
    /// The predecessor-ancestry gate (P9.2) found the named predecessor Feature not yet landed in one
    /// or more repositories: the author Act authored nothing, dispatched nothing. A quiet Night, not a failure.
    case authoringPredecessorNotLanded(featureIssueID: String, repositories: [String])
    /// The predecessor-ancestry gate (P9.2) evaluated a pass of ancestry for the predecessor Feature:
    /// the merged fraction k of N repositories observed on this pass.
    case predecessorAncestryObserved(
        featureIssueID: String, mergedRepositories: [String], unmergedRepositories: [String]
    )
    /// The predecessor-ancestry gate's merge test found an unmerged repository whose Feature Branch
    /// will not merge cleanly into mainline: a Mainline Conflict. Reported only — no Card state
    /// changes, no Block Reason.
    case mainlineConflictDetected(featureIssueID: String, repository: String, paths: [String])
    case managedBlockDelimiterBroken(issueID: String)
    /// Fire-and-forget: the failure is recorded, never acted on.
    case notificationDeliveryFailed(notification: String, reason: String)
    /// The board's request budget was exhausted and the Act did less work. The budget is the
    /// identity's, shared by every Project running that night, so the record names it workspace-wide
    /// and never attributes the exhaustion to this Project's own reads.
    case rateBudgetExhausted(degradation: String)
    /// An expired Act-scoped lease was taken over by a new run: the previous run crashed or slept past its TTL.
    case leaseReclaimed(previousRunID: RunID, previousAct: Act, expiredAt: Date)
    /// An expired Card-scoped lease was taken over by a new run: the previous run crashed or slept past its TTL.
    case cardLeaseReclaimed(cardID: Int64, previousRunID: RunID, expiredAt: Date)
    /// The first Act of the Night recorded it, before any work.
    case nightOpened
    /// The Night closed, with the reason it closed.
    case nightClosed(reason: NightCloseReason)
    /// This Project's previous Night was left open with no completion: it opened and died. Recorded
    /// on the next Night, by its first Act, which is the only thing alive to draw the conclusion.
    case nightOpenedAndDied(nightID: Int64, nightStart: NightStart)
    /// The SHA-256 of the human prose outside the delimiters, recorded for provenance on every
    /// description write.
    case managedBlockWritten(issueID: String, preservedProseHash: String, renderedHash: String)
    /// The first Act of the Night created that Project's Night Card, before any work (DR7).
    case nightCardOpened(issueID: String)
    /// The land firing at `night_end` completed the Night Card with the Night Summary.
    case nightCardCompleted(issueID: String)
    /// A permanent board write failure, surfaced in the Night Summary because a silent projection
    /// failure makes every other guarantee unreadable.
    case boardWriteFailed(clientID: UUID, operation: String, issueID: String?, reason: String)
    /// An all-or-nothing group of writes (the authoring transaction) failed part-way and its applied
    /// creates were archived.
    case outboxGroupRolledBack(groupID: String, reason: String)
    /// The board read the Card as Cancelled; the Journal records its previous state for reopening.
    case cardCancelled(cardID: Int64, issueID: String, previousState: CardState)
    /// The board read a Journal-cancelled Card as reopened; the Journal restores its previous state.
    case cardReopened(cardID: Int64, issueID: String, restoredState: CardState)
    /// The board moved a Card to a state the Journal did not write; the Journal stays authoritative
    /// and records the discrepancy.
    case cardRestated(cardID: Int64, issueID: String, journalState: CardState, boardState: String)
    /// The board no longer lists this Card; the Journal records how it was removed.
    case cardRemovedFromBoard(cardID: Int64, issueID: String, how: String)
    /// A Card violates an invariant that must hold for authoring to proceed; the Journal records
    /// what broke so no Act blindly retries.
    case authoringInvariantBroken(cardID: Int64, issueID: String, reason: String)
    /// A Delta Read completed, reporting object counts and the sync point it reads next.
    case deltaReadCompleted(
        objects: Int, comments: Int, ownComments: Int, requests: Int,
        since: Date?, syncPoint: Date?
    )
    /// A Journal-side Card state transition (roadmap P5.8): the state, waiting reason and block reason
    /// the Card holds after it, bumping `card.state_version` in the same write.
    case cardStateTransitioned(
        cardID: Int64, issueID: String, from: CardState, to: CardState,
        waitingReason: WaitingReason?, blockReason: BlockReason?
    )
    /// The Delta Read found a Card in Waiting on You with no Journal record behind it: an unknown
    /// object labelled Card, or a known Card whose Journal state is Waiting on You with no waiting
    /// reason recorded. Never dispatched.
    case waitingOnYouUnbacked(issueID: String, cardID: Int64?, reason: String)
    /// A build Act's reconciliation (loop-state/reconcile-worktrees-at-act-start) found a held
    /// Worktree's recorded path gone: a ghost Worktree. The loss of build state is noted in the
    /// Journal so the morning understands why it started cold.
    case worktreeLost(featureID: Int64, repository: String, worktreeID: String, path: String)
    /// Reconciliation's process fencing killed at least one process still holding a Worktree before
    /// reconciliation inspected or touched it.
    case worktreeFenced(featureID: Int64, repository: String, path: String, killed: Int)
    /// Processes still held a Worktree after the fencing timeout; reconciliation did not proceed past
    /// it — nothing was inspected, committed or reset.
    case worktreeNotQuiescent(featureID: Int64, repository: String, path: String, remaining: Int)
    /// Reconciliation committed uncommitted work in a Worktree as a WIP commit on the Feature Branch.
    /// `resetTo` is the last known-good commit the Worktree was reset to, nil when none is recorded.
    case worktreeWIPCommitted(
        featureID: Int64, repository: String, wipCommit: String, wipRef: String, resetTo: String?
    )
    /// A git step of reconciliation refused or failed; nothing was destroyed. `reason` says what.
    case worktreeReconciliationFailed(featureID: Int64, repository: String, path: String, reason: String)
    /// Route resolution left zero candidates for the Card — fallbacks exhausted
    /// (routing/resolve-a-route-for-a-card, OQ13): the Card moved to Blocked with Block Reason
    /// `hard failure`, no Attempt was recorded, and `reason` names every candidate and what dropped it.
    case routeExhausted(cardID: Int64, issueID: String, reason: String)
    /// The Operator's Override could not resolve, or pinned a CLI that failed its Probe: a Readiness
    /// Check failure (G-17). Nothing was dispatched, no Attempt was recorded and the Card's state was
    /// not touched.
    case overrideRefused(cardID: Int64, issueID: String, reason: String)
    /// An Attempt ended, with its outcome and whether it excluded the Route it ran on
    /// (routing/exclude-tried-routes-on-retry, P7.7).
    case attemptEnded(
        cardID: Int64, issueID: String, attemptID: Int64, route: Route, outcome: String, routeExcluded: Bool
    )
    /// A second (or later) Attempt in the same budget epoch was recorded, and whether it landed on a
    /// Route no earlier Attempt in that epoch had tried (routing/exclude-tried-routes-on-retry, P7.7).
    case routeRetried(cardID: Int64, issueID: String, attemptID: Int64, route: Route, differentRoute: Bool)
    /// An Override pinned in triage reset the Card's budget epoch, so a Route excluded in an earlier
    /// epoch no longer excludes (routing/exclude-tried-routes-on-retry, P7.7).
    case budgetEpochReset(cardID: Int64, issueID: String, from: Int, to: Int, reason: String)
    /// The build Act's lease sweep (the Journal half of loop-state/reclaim-an-expired-lease, P8.10)
    /// reclaimed every Card whose lease a dead run left expired, before Worktree reconciliation.
    case expiredCardLeasesSwept(cycleID: Int64, reclaimedCardIDs: [Int64])
    /// The build Act reposted every Card whose board projection had not caught up with its Journal
    /// state.
    case boardStateReposted(cards: Int)
    /// The build Act derived this Cycle's Repo Lanes from its Cards, read fresh after the Delta Read.
    case repoLanesDerived(cycleID: Int64, lanes: [String])
    /// A Repo Lane started running its Cards, one at a time in authored order.
    case repoLaneStarted(repository: String, cards: Int)
    /// A Repo Lane finished — every runnable Card ran, or one of them threw and stopped the lane.
    /// `cardsSkipped` is how many the Readiness Check (P8.2) found not Ready and moved past; 0 on a row
    /// recorded before that check existed.
    case repoLaneEnded(repository: String, cardsRun: Int, failure: String?, cardsSkipped: Int = 0)
    /// The Readiness Check found a Card Ready to dispatch (board-projection/check-card-readiness-at-dispatch, P8.2).
    case readinessCheckPassed(cardID: Int64, issueID: String)
    /// The Readiness Check found a Card not Ready: it was not dispatched, consuming no Attempt.
    case readinessCheckFailed(cardID: Int64, issueID: String, failures: [String])
    /// A Transcription Block's provenance test returned `.stale`: the Card is a Divergence.
    case cardDiverged(cardID: Int64, issueID: String, repository: String, changedPaths: [String])
    /// An Operator edit inside a Transcription Block voided its stamp: it is now Operator-supplied.
    case transcriptionStampVoided(cardID: Int64, issueID: String, repository: String)
    /// An untagged Definition of Done line on the board was minted a synthetic clause id.
    case clauseMinted(issueID: String, cid: String)
    /// A tagged clause's text or citation changed on the board; its identity (`cid`) is preserved.
    case clauseInvalidated(issueID: String, cid: String, cause: String)
    /// A tagged clause present in the Journal is absent from the board.
    case clauseDeleted(issueID: String, cid: String)
    /// A Card scoped onto a protected path was refused before dispatch: not dispatched, no Attempt
    /// consumed (bounds/refuse-protected-paths-before-dispatch, P8.3).
    case protectedPathRefused(
        cardID: Int64, issueID: String, repository: String, declaredPath: String, protectedPath: String
    )
    /// One step of running a Card to completion (graph-execution/run-a-card, P8.4): the Lease claimed,
    /// the Attempt started, each pass and the Check, the Lease released. `detail` is what the step
    /// yielded, when it yielded anything worth naming.
    case cardRunStep(cardID: Int64, issueID: String, step: CardRunStep, detail: String?)

    /// The engine-run Check ran over an Attempt's work (P8.5), pass or fail or declared none. `output` is
    /// what it printed, already capped by the runner; it is empty or nil when nothing ran.
    case checkRan(
        cardID: Int64, issueID: String, attemptID: Int64, result: CheckRunResult, exitStatus: Int32?, output: String?
    )

    /// The fence → WIP-commit → preserve → reset sequence preserved an Attempt's work under a git ref
    /// before resetting the Worktree and the Feature Branch tip to `resetTo`, the last known-good
    /// commit (Attempt, Block and Reset Ruling 2026-09-19, OQ60).
    case attemptWorkPreserved(
        cardID: Int64, issueID: String, attemptID: Int64, ref: String, commit: String, resetTo: String
    )
    /// A failed Attempt's cause was counted against the Card (loop-state/record-failure-cause-recurrence,
    /// P8.8). `recurrenceCount` is how many separate Nights have met `causeHash`: above 1 it is a
    /// recurrence rather than a first occurrence.
    case failureCauseRecorded(
        cardID: Int64, issueID: String, cause: String, causeHash: String, recurrenceCount: Int
    )
    /// A Repo Lane's Card ended Blocked or Waiting on You without stopping the lane: it is a hole in
    /// the Feature (graph-execution/handle-a-block-mid-graph, P8.9), named in the Partial Landing
    /// announcement (P10.4) and left for the lane to run past.
    case laneHoleRecorded(cardID: Int64, issueID: String, repository: String, state: CardState)
    /// A build Act's lease-reclaim sweep (loop-state/reclaim-an-expired-lease, P8.10) took over a dead
    /// run's Card Lease and reposted the Card's board state. `attemptID` and `outcome` (the classified
    /// Attempt's Operator-facing `consumed_how` account) are nil when no Attempt was open to classify,
    /// or the Pre-Reclaim Quiescence Gate found the Worktree not quiescent and classification never ran.
    case cardReclaimed(
        cardID: Int64, issueID: String, previousRunID: RunID, attemptID: Int64?, outcome: String?,
        routeExcluded: Bool
    )
    /// The Pre-Reclaim Quiescence Gate found the Card's Worktree still held after the fencing timeout
    /// (loop-state/reclaim-an-expired-lease, P8.10): the Lease claim stands, but nothing was classified
    /// or reposted, and the Attempt (if any) is left open for the next Act to try again. Distinct from
    /// `.cardReclaimed` so the Night Summary never confuses a deferral with a real reclaim that happened
    /// to find no open Attempt.
    case cardReclaimDeferred(cardID: Int64, issueID: String, previousRunID: RunID, remaining: Int)
    /// A pass actually spawned an agent CLI process (system-overview, Environment Differences, P8.11):
    /// the conservative default for every dispatch that does not say otherwise.
    case agentCLIProcessSpawned(cardID: Int64, issueID: String, attemptID: Int64, pass: RunPass, cli: String)
    /// A rehearsal Night's pass was answered from a fixture instead of spawning an agent CLI process
    /// (system-overview, Environment Differences, P8.11): one of the three rehearsal boundaries held.
    case rehearsalFixtureAnswered(cardID: Int64, issueID: String, attemptID: Int64, pass: RunPass, fixture: String)
    /// The author Act's selection (roadmap P9.3) selected exactly one Feature and validated it:
    /// repositories resolved to this Project's own, adoption candidates narrowed to real ones.
    case featureSelected(FeatureSelectedPayload)
    /// The author Act's selection halted before any dispatch (feature-authoring/select-the-next-feature,
    /// second and fourth stories): `reasonKind` is ``AuthoringHaltReason/kind``, `detail` is the seam or
    /// repository it names.
    case featureAuthoringHalted(name: String, reasonKind: String, detail: String?)
    /// The authoring transaction (roadmap P9.4) accepted its Outbox group and recorded its plan, in one
    /// Journal transaction — the record a resumed author Act finishes from.
    case featureAuthoringAccepted(FeatureAuthoringAcceptedPayload)
    /// The board applied the whole group and the Feature, Cycle and Card rows were written.
    case featureAuthored(FeatureAuthoredPayload)
    /// The group was rolled back: no Feature, Cycle or Card row was written and no partial board is left.
    case featureAuthoringFailed(name: String, groupKey: String, reason: String)

    // `type`, the exhaustive switch from a case to its `JournalEventType`, lives in
    // JournalEvent+Type.swift, split out to keep this file under the file length limit.
}

/// The type of a JournalEvent, with raw values matching the spec's PascalCase names.
public enum JournalEventType: String, CaseIterable, Sendable {
    case actStarted = "ActStarted"
    case actEnded = "ActEnded"
    case actIdle = "ActIdle"
    case actIncomplete = "ActIncomplete"
    case actStoodDown = "ActStoodDown"
    case mainlineFetchFailed = "MainlineFetchFailed"
    case absentNightDetected = "AbsentNightDetected"
    case authoringNoWorkAvailable = "AuthoringNoWorkAvailable"
    case authoringSkippedFeatureInFlight = "AuthoringSkippedFeatureInFlight"
    case authoringPredecessorNotLanded = "AuthoringPredecessorNotLanded"
    case predecessorAncestryObserved = "PredecessorAncestryObserved"
    case mainlineConflictDetected = "MainlineConflictDetected"
    case managedBlockDelimiterBroken = "ManagedBlockDelimiterBroken"
    case notificationDeliveryFailed = "NotificationDeliveryFailed"
    case rateBudgetExhausted = "RateBudgetExhausted"
    case leaseReclaimed = "LeaseReclaimed"
    case cardLeaseReclaimed = "CardLeaseReclaimed"
    case nightOpened = "NightOpened"
    case nightClosed = "NightClosed"
    case nightOpenedAndDied = "NightOpenedAndDied"
    case managedBlockWritten = "ManagedBlockWritten"
    case nightCardOpened = "NightCardOpened"
    case nightCardCompleted = "NightCardCompleted"
    case boardWriteFailed = "BoardWriteFailed"
    case outboxGroupRolledBack = "OutboxGroupRolledBack"
    case cardCancelled = "CardCancelled"
    case cardReopened = "CardReopened"
    case cardRestated = "CardRestated"
    case cardRemovedFromBoard = "CardRemovedFromBoard"
    case authoringInvariantBroken = "AuthoringInvariantBroken"
    case deltaReadCompleted = "DeltaReadCompleted"
    case cardStateTransitioned = "CardStateTransitioned"
    case waitingOnYouUnbacked = "WaitingOnYouUnbacked"
    case worktreeLost = "WorktreeLost"
    case worktreeFenced = "WorktreeFenced"
    case worktreeNotQuiescent = "WorktreeNotQuiescent"
    case worktreeWIPCommitted = "WorktreeWIPCommitted"
    case worktreeReconciliationFailed = "WorktreeReconciliationFailed"
    case routeExhausted = "RouteExhausted"
    case overrideRefused = "OverrideRefused"
    case attemptEnded = "AttemptEnded"
    case routeRetried = "RouteRetried"
    case budgetEpochReset = "BudgetEpochReset"
    case expiredCardLeasesSwept = "ExpiredCardLeasesSwept"
    case boardStateReposted = "BoardStateReposted"
    case repoLanesDerived = "RepoLanesDerived"
    case repoLaneStarted = "RepoLaneStarted"
    case repoLaneEnded = "RepoLaneEnded"
    case readinessCheckPassed = "ReadinessCheckPassed"
    case readinessCheckFailed = "ReadinessCheckFailed"
    case cardDiverged = "CardDiverged"
    case transcriptionStampVoided = "TranscriptionStampVoided"
    case clauseMinted = "ClauseMinted"
    case clauseInvalidated = "ClauseInvalidated"
    case clauseDeleted = "ClauseDeleted"
    case protectedPathRefused = "ProtectedPathRefused"
    case cardRunStep = "CardRunStep"
    case checkRan = "CheckRan"
    case attemptWorkPreserved = "AttemptWorkPreserved"
    case failureCauseRecorded = "FailureCauseRecorded"
    case laneHoleRecorded = "LaneHoleRecorded"
    case cardReclaimed = "CardReclaimed"
    case cardReclaimDeferred = "CardReclaimDeferred"
    case agentCLIProcessSpawned = "AgentCLIProcessSpawned"
    case rehearsalFixtureAnswered = "RehearsalFixtureAnswered"
    case featureSelected = "FeatureSelected"
    case featureAuthoringHalted = "FeatureAuthoringHalted"
    case featureAuthoringAccepted = "FeatureAuthoringAccepted"
    case featureAuthored = "FeatureAuthored"
    case featureAuthoringFailed = "FeatureAuthoringFailed"
}
