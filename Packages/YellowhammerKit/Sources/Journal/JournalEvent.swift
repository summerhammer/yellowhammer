import Domain
import Foundation
// swiftlint:disable file_length

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
    /// This Act halted on a Linear authorization failure (roadmap P17.5, Linear Board Connection
    /// Ruling items 5, 12, 13): `BoardError.notAuthenticated` — a refused refresh, a revoked
    /// Installation, a 401 surviving one retry, or no Installation at all. Appended alongside
    /// `.actIncomplete` for this cause; a Night whose every Act only ever recorded this spends none of
    /// `overdue_nights_max` (no clock reads this event — it simply never advances, since nothing
    /// dispatched).
    case linearAuthorizationHalted
    /// One attempt to refresh the Board Connection's token pair, succeeded or refused. Carries no token.
    case appInstallationTokenRefresh(AppInstallationTokenRefresh)
    case mainlineFetchFailed(repository: String, reason: String)
    /// The resumption self-audit found a Night that never opened (OQ12): a calendar date
    /// between two recorded Nights with no Night row. Recorded on the Night that resumed, by its
    /// first Act. Reported, never acted on — `overdue_nights_max` is spent only by Nights that ran.
    case absentNightDetected(nightStart: NightStart)
    case authoringNoWorkAvailable
    /// The author Act found a Feature already in flight for this Project (an open Cycle) and authored
    /// nothing: never more than one Feature in flight per Project, even forced. A quiet Night, not a failure.
    case authoringSkippedFeatureInFlight(featureIssueID: String)
    /// The predecessor-ancestry gate (P9.2) found the named predecessor Feature not yet landed in one
    /// or more repositories: the author Act authored nothing, dispatched nothing. A quiet Night, not a failure.
    case authoringPredecessorNotLanded(featureIssueID: String, repositories: [String])
    /// The predecessor-ancestry gate (P9.9) could not find the predecessor Feature's Feature Branch in
    /// one or more repositories that have no recorded landing either: the author Act authored nothing,
    /// dispatched nothing. A quiet Night, not a failure.
    case authoringPredecessorIndeterminate(featureIssueID: String, repositories: [String])
    /// The predecessor walk (roadmap P9.9) stepped past a released Feature on its way to the
    /// predecessor to check: more recent than the predecessor, its Cycle archived, and released. A
    /// released Feature satisfies the gate for no repository and is never itself checked.
    case predecessorWalkSkippedReleasedFeature(featureIssueID: String)
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
    /// Orca ADE reported a branch for a requested Worktree that Yellowhammer does not accept; the build
    /// Act halted. `requested` is the branch Yellowhammer expected (the recorded Feature Branch when one is
    /// recorded, else the requested Worktree name); `reported` is what Orca ADE made.
    case worktreeNameCollision(repository: String, requested: String, reported: String)
    /// An Act found part of the Project's board scope unresolved (missing, or a name collision) and did
    /// no work (OQ85, OQ136). `steps` names every unresolved item, joined with "; ".
    case boardScopeUnresolved(steps: String)
    /// The board's request budget was exhausted and the Act did less work. The budget is the
    /// Board Connection's, shared by every Project on that installation, so the record names it
    /// installation-wide (and the workspace, when known) and never attributes the exhaustion to this
    /// Project's own reads.
    case rateBudgetExhausted(degradation: String, installation: AppInstallationLabel? = nil)
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
    /// The Night Card's completion was still pending when the closing Act ended; the Outbox replays it on a
    /// later Act.
    case nightCardCompletionDeferred(issueID: String, entryIDs: [Int64], reason: String)
    /// A permanent board write failure, surfaced in the Night Summary because a silent projection
    /// failure makes every other guarantee unreadable.
    case boardWriteFailed(clientID: UUID, operation: String, issueID: String?, reason: String)
    /// An all-or-nothing group of writes (the authoring transaction) failed part-way and its applied
    /// creates were archived.
    case outboxGroupRolledBack(groupID: String, reason: String)
    /// The board read the Card as Shelved; the Journal records its previous state for reopening.
    case cardShelved(cardID: Int64, issueID: String, previousState: CardState)
    /// The board read a Journal-shelved Card as reopened; the Journal restores its previous state.
    case cardReopened(cardID: Int64, issueID: String, restoredState: CardState)
    /// The board moved a Card to a state the Journal did not write; the Journal stays authoritative
    /// and records the discrepancy.
    case cardRestated(cardID: Int64, issueID: String, journalState: CardState, boardState: String)
    /// A human comment observed by the Delta Read on a known Card; comment id makes re-reads harmless.
    case humanCardComment(cardID: Int64, commentID: String, commentedAt: Date)
    /// The board no longer lists this Card; the Journal records how it was removed.
    case cardRemovedFromBoard(cardID: Int64, issueID: String, how: String)
    /// The board restored a removed Card's issue (un-trashed or unarchived, OQ142): the Card is back
    /// in play exactly as it stood. `how` is how it had been removed.
    case cardRestoredToBoard(cardID: Int64, issueID: String, how: String)
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
    /// Journal so the morning understands why it started cold. `pinnedCommit` is the Feature Branch tip
    /// the purge pinned at `refs/yellowhammer/recovery/<branch>` first (OQ123) — the tip the next
    /// allocation recovers from: the branch's tip, or — with the branch already gone — the lane's
    /// `last_known_good_commit` (OQ133); nil when nothing was recoverable. In that case `lostCommit` is the
    /// `last_known_good_commit` whose object is gone too (nil when none was recorded) and `lostDoneCardIDs`
    /// the Done Cards of the lane whose commits went with it — the loss the Night Summary names. Both are
    /// empty when the lane's work was pushed, which survives on the remote.
    case worktreeLost(
        featureID: Int64, repository: String, worktreeID: String, path: String, pinnedCommit: String?,
        lostCommit: String? = nil, lostDoneCardIDs: [Int64] = []
    )
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
    /// `route failure`, no Attempt was recorded, and `reason` names every candidate and what dropped it.
    case routeExhausted(cardID: Int64, issueID: String, reason: String)
    /// The Operator's Override could not resolve, pinned a Route whose CLI failed its Probe, or pinned a
    /// Route that failed its Route Pre-flight: a Readiness Check failure (G-17, OQ126). Nothing was
    /// dispatched, no Attempt was recorded and the Card's state was not touched.
    case overrideRefused(cardID: Int64, issueID: String, reason: String)
    /// A Route Pre-flight ran (OQ126): the Route's CLI was run once with its model and effort on a trivial
    /// prompt, or a rehearsal fixture answered in its place. Stamped with the Night, it is the verdict
    /// every later Card pinned to the same Route reads for the rest of that Night. `reason` says why it
    /// failed, or what answered in place of the CLI.
    case routePreflightRan(route: Route, passed: Bool, reason: String?)
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
    /// A worker pass returned a question: the Attempt ends `question`, consuming no Round and no
    /// Attempt, and the Card moves to Waiting on You (roadmap P11.1; spec: bounds/escalate-a-question-
    /// to-the-operator).
    case cardQuestionAsked(cardID: Int64, issueID: String, attemptID: Int64)
    /// A human comment on a Card in Waiting on You was classified and recorded (roadmap P11.2; spec:
    /// bounds/escalate-a-question-to-the-operator, board-projection/read-board-changes-by-delta):
    /// `disposition` is `answer` (a threaded reply to the latest recorded question), `remark` (any other
    /// comment against a `question` waiting reason), or `divergence` / `overreach` (comments against
    /// their respective waiting reasons). Recorded inside the Delta Read, idempotent on the board comment
    /// id: a replay appends no second event.
    case waitingOnYouReplyRecorded(cardID: Int64, issueID: String, commentID: String, disposition: String)
    /// A Card Reply was banked (roadmap P11.3): the Feature that put its Card in Waiting on You has
    /// landed, so the answer is recorded and stamped with each touched Repo's mainline rather than
    /// dispatched — appended once, on first banking, never on a replayed idempotent bank.
    case waitingOnYouReplyBanked(cardID: Int64, issueID: String, commentID: String)
    /// One step of running a Card to completion (graph-execution/run-a-card, P8.4): the Lease claimed,
    /// the Attempt started, each pass and the Check, the Lease released. `detail` is what the step
    /// yielded, when it yielded anything worth naming.
    case cardRunStep(cardID: Int64, issueID: String, step: CardRunStep, detail: String?)

    /// The engine-run Check ran over an Attempt's work (P8.5), pass or fail or declared none. `output` is
    /// what it printed, already capped by the runner; it is empty or nil when nothing ran. `judgedCommit`
    /// is the worker commit the Check judged: a passing Check writes no Round, so this event is the only
    /// place a Check's result is tied to a commit. `nil` on events written before it was recorded.
    case checkRan(
        cardID: Int64, issueID: String, attemptID: Int64, result: CheckRunResult, exitStatus: Int32?, output: String?,
        judgedCommit: String?
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
    /// One commit the worker reported (or that the reported range reached) carries no `Yellowhammer-Work-Card`
    /// trailer (graph-execution/run-a-card). Recorded only: it never changes the Card's outcome, never
    /// creates a Round, and is not shown in the Roll-up (OQ102).
    case cardCommitTrailerMissing(cardID: Int64, issueID: String, attemptID: Int64, commit: String)
    /// The engine could not read the worker's reported commits with `git log` (for example the commit
    /// does not exist), so their trailers went unchecked. Recorded instead of failing the Card: it never
    /// changes the Card's outcome, never creates a Round, and is not shown in the Roll-up (OQ102).
    case cardCommitTrailersUnread(cardID: Int64, issueID: String, attemptID: Int64, commit: String, reason: String)
    /// One process a Card run's leftover accounting named (Normal-Exit Sweep Ruling, issue #175):
    /// swept by the agent CLI process lifecycle's own identity sweep, killed by the attributed
    /// Worktree fence, or found holding the Worktree but left running because it could not be
    /// attributed to this run. `cwd` is the process's working directory when the fence recorded it
    /// unattributed; nil otherwise (a swept process's cwd is not recorded).
    case leftoverProcessRecorded(
        cardID: Int64, issueID: String, attemptID: Int64, pass: RunPass, pid: Int32, commandName: String,
        disposition: LeftoverProcessDisposition, cwd: String?
    )
    /// The author Act's selection (roadmap P9.3) selected exactly one Feature and validated it:
    /// repositories resolved to this Project's own, adoption candidates narrowed to real ones.
    case featureSelected(FeatureSelectedPayload)
    /// The author Act's selection halted before any dispatch (feature-authoring/select-the-next-feature,
    /// second and fourth stories): `reasonKind` is ``AuthoringHaltCause/kind``, `detail` is the seam or
    /// repository it names.
    case featureAuthoringHalted(name: String, reasonKind: String, detail: String?)
    /// The authoring transaction (roadmap P9.4) accepted its Outbox group and recorded its plan, in one
    /// Journal transaction — the record a resumed author Act finishes from.
    case featureAuthoringAccepted(FeatureAuthoringAcceptedPayload)
    /// The board applied the whole group and the Feature, Cycle and Card rows were written.
    case featureAuthored(FeatureAuthoredPayload)
    /// The group was rolled back: no Feature, Cycle or Card row was written and no partial board is left.
    case featureAuthoringFailed(name: String, groupKey: String, reason: String)
    case featureBreakdownRejected(name: String, reason: String)
    /// One authoring pass (selection or breakdown) was dispatched under the reserved authoring Kind and
    /// answered (roadmap P9.11): `route` is the Route's description, `ordinal` the 1-based candidate tried
    /// in this Act, and `fixture` the rehearsal fixture that answered — nil when an agent CLI process ran.
    case authoringDispatched(pass: RunPass, route: String, ordinal: Int, fixture: String?)
    /// Selection ended the author Act without choosing a Feature (roadmap P9.11): every candidate Route
    /// failed, was unavailable or crashed, or the Routing Table had none. An authoring fault, not a halt
    /// — there is no Feature name yet.
    case featureSelectionFailed(reason: String)
    /// A Feature's uncitable-Definition-of-Done halt opened a new Refusal (roadmap P9.7; glossary:
    /// Refusal): no `open` (or `expired`) Refusal existed for this Feature name yet.
    /// `uncitableClauses` is the compact listing of the clauses no citation supported, and
    /// `reselectionDepth` how deep in the backlog the Feature sat (P9.8); rows written before then
    /// decode as "" and 0.
    case refusalOpened(
        feature: String, consecutiveRefusals: Int, uncitableClauses: String = "", reselectionDepth: Int = 0
    )
    /// A Feature was refused again while its Refusal was already `open` (or already `expired`): the
    /// consecutive count moved, but the Night-driven clock did not — a repeat refusal never restarts it.
    case refusalRepeated(
        feature: String, consecutiveRefusals: Int, uncitableClauses: String = "", reselectionDepth: Int = 0
    )
    /// The Refusal's unanswered-Nights clock exceeded `bound` (bounds/bound-unanswered-nights): the
    /// row moved to `expired`. `issueID` is nil when the Feature Issue's create had not yet applied.
    case refusalExpired(feature: String, issueID: String?, unansweredNights: Int, bound: Int)
    /// A clean authoring run reset this Feature's consecutive-refusals count and closed its `answered`
    /// and `open` Refusals so they leave the clock; it never answers one. Appended only when there was
    /// something to change.
    case refusalCountReset(feature: String)
    /// One step of the land Act's sequence (roadmap P10.1): a Repo Lane's merge test, push, open pull
    /// request or Worktree release, or the Feature's Verification, return or Cycle archive.
    /// `repository` is nil for the three Feature-scoped steps.
    case landStep(step: LandStep, repository: String?, outcome: LandStepOutcome, detail: String?)
    /// The land Act landed this Cycle: once per Cycle (risks OQ8), so a later firing's trigger goes
    /// false and no Repo Lane re-opens even if a Card returns to Todo.
    case cycleLanded(cycleID: Int64)
    /// A touched repository's Repo Lane produced no completed work, so its Feature Branch is at its base:
    /// never pushed, no pull request (glossary: No-Pushed-Branch Outcome; risks OQ104, OQ107). Recorded,
    /// not a failure; it takes `repository` out of the set the merged fraction and the predecessor gate
    /// read (``JournalStore/pushedRepositories(featureID:)``). Appended once per Feature and repository.
    case noPushedBranchOutcome(cycleID: Int64, featureIssueID: String, repository: String)
    /// Verification judged this Cycle's Definition of Done clause by clause (roadmap P10.5): once per
    /// Cycle. Counts only — never a pass/fail headline; the per-clause verdicts are in the report.
    case featureVerified(cycleID: Int64, met: Int, unmet: Int, unresolved: Int)
    /// A Feature was returned to the Operator for unmet or unresolved clauses (roadmap P10.6): appended
    /// only on the Feature's first transition into `returned`. Counts only — the per-clause detail is
    /// in the return comment.
    case featureReturned(cycleID: Int64, featureIssueID: String, unmet: Int, unresolved: Int)
    /// A verified Feature's Cycle was archived (roadmap P10.7): appended only on the Cycle's first
    /// archival. `detachedCards` counts the Blocked Cards detached from the Feature Issue in the same
    /// pass, left for later adoption.
    case cycleArchived(cycleID: Int64, featureIssueID: String, closedBy: FeatureClosure, detachedCards: Int)
    /// A Feature was closed by merge (roadmap P10.8; spec: landing/announce-a-partial-landing,
    /// morning-report/triage-the-morning): the predecessor-ancestry gate observed every touched
    /// repository merged. `repositories` are the merged repositories (sorted); `carriedForward` and
    /// `acceptedCards` are the Cycle's Blocked and Done Cards' issue ids (sorted); `triagedNightID`
    /// names the Night whose morning the merge concluded, per the triaged-Night rule.
    case featureClosedByMerge(
        cycleID: Int64, featureIssueID: String, repositories: [String], carriedForward: [String],
        acceptedCards: [String], triagedNightID: Int64
    )
    /// A Spec Citation answered the Feature's Refusal (P9.8): `from` is the state it was in, `open` or
    /// `expired`. The consecutive count is untouched.
    case refusalAnswered(feature: String, citation: String, from: String)
    /// A Feature's authoring stopped without a thin specification — an Authoring Halt (P9.8; glossary:
    /// Authoring Halt) — and no `open` or `expired` halt existed for it yet. `causeKind` is
    /// ``AuthoringHaltCause/kind``; `detail` the repository or path it names.
    case authoringHaltOpened(feature: String, causeKind: String, detail: String?)
    /// The Feature halted again while its halt was already `open`: the content moved, the clock did not.
    case authoringHaltRepeated(feature: String, causeKind: String, detail: String?)
    /// The halt's unanswered-Nights clock exceeded `bound`; the row moved to `expired`.
    case authoringHaltExpired(feature: String, issueID: String?, unansweredNights: Int, bound: Int)
    /// The Feature's next clean authoring run cleared its `open` or `expired` halt.
    case authoringHaltCleared(feature: String)
    /// The Operator's settle gesture (roadmap P10.9; spec: morning-report/triage-the-morning) read
    /// *kept in flight* on the Feature Issue: the Feature stays in flight. `acceptedCards` are the
    /// Cycle's Done Cards' issue ids (sorted); `triagedNightID` names the Night whose morning was
    /// triaged, per the settle triaged-Night rule (the latest earlier Night, or this Night itself).
    /// Appended only when this call newly wrote `night.triaged_at` — first write wins — so a repeated
    /// Act of the same Night appends nothing further.
    case featureSettled(cycleID: Int64, featureIssueID: String, acceptedCards: [String], triagedNightID: Int64)
    /// The Operator's settle gesture (roadmap P10.9) read *released*: the Feature is released,
    /// stop-with-salvage. `carriedForward` and `acceptedCards` are the Cycle's Blocked and Done Cards'
    /// issue ids (sorted); `abandonedRepositories` are the touched repositories with a recorded pull
    /// request but no recorded landing (sorted); `triagedNightID` is the settle triaged-Night rule's
    /// result. Appended only on the Feature's first release — idempotent, like ``featureClosedByMerge``.
    case featureReleased(
        cycleID: Int64, featureIssueID: String, carriedForward: [String], acceptedCards: [String],
        abandonedRepositories: [String], triagedNightID: Int64
    )
    /// The settle gesture read a value the offered set did not include for this pass (roadmap P10.9) —
    /// e.g. *kept in flight* read on a Partial Landing (or with every Card Shelved), where only
    /// *abandoned* is offered. Not honoured: treated as unsettled, and nothing else is written.
    case settleValueNotHonoured(featureIssueID: String, value: String, reason: String)
    /// A Card's unanswered-Nights clock exceeded `bound` (bounds/bound-unanswered-nights): it is being
    /// auto-Blocked. `blockReason` is `reply overdue` on the `question` route, `decision overdue` on `divergence`.
    case cardUnansweredBoundFired(
        cardID: Int64, issueID: String, unansweredNights: Int, bound: Int, blockReason: String
    )
    /// A Card selection tried to adopt was refused: a stale Transcription Block (roadmap P11.5). Not
    /// adopted, not re-authored; a Divergence, sibling of Refusal. `featureName` names the Feature that
    /// tried — its Feature Issue does not exist yet, since re-validation precedes drafting.
    case adoptionRefused(
        cardID: Int64, issueID: String, nightID: Int64, featureName: String, staleBlocks: [AdoptionStaleBlock]
    )
    /// A Card was adopted cleanly into a successor Feature (P11.5): cold in a fresh Worktree.
    case cardAdopted(
        cardID: Int64, issueID: String, previousFeatureIssueID: String, newFeatureIssueID: String,
        priorBlockReason: String?, coldStartNote: String
    )
    /// A Card a selection tried to adopt had untestable provenance (P11.5): not adopted, not refused.
    case adoptionUntestable(cardID: Int64, issueID: String, featureName: String, reasons: [String])
    /// P11.6, see FeatureSelection/JournalStore+Refusals/+AdoptionRefusal, the writers of these four.
    case featureReselected(depth: Int, afterRefusalOf: String, reselectionsMax: Int)
    case reselectionBoundReached(depth: Int, reselectionsMax: Int)
    case refusalPromotedToStandingItem(feature: String, consecutiveRefusals: Int, consecutiveRefusalsMax: Int)
    case cardPromotedToStandingItem(cardID: Int64, issueID: String, failedAdoptions: Int, failedAdoptionsMax: Int)
    /// Explicit Project removal completed (roadmap P13.5; spec risks OQ52(1)): appended once, whether or
    /// not there was anything to close, archive or release. `featureIssueID` is the in-flight Feature
    /// Issue commented on, nil when none was in flight. `removedWorktrees` and `keptWorktrees` are the
    /// repositories whose held Worktree was removed and left in place respectively (a dirty Worktree in
    /// rehearsal, say).
    case projectRemoved(featureIssueID: String?, removedWorktrees: [String], keptWorktrees: [String])

    // `type`, the exhaustive switch from a case to its `JournalEventType`, lives in
    // JournalEvent+Type.swift, split out to keep this file under the file length limit.
    // `AdoptionStaleBlock` (the payload of `adoptionRefused`) lives in JournalEvent+AdoptionDecoding.swift,
    // for the same reason.
}
