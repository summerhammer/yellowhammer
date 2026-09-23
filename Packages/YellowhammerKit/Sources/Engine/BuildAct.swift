import Domain
import Foundation
import Journal
import Repositories

/// The build Act's work (roadmap P8.1; spec: graph-execution/overview,
/// shift-scheduling/fire-an-act-on-schedule), in this order:
///
/// 1. Sweeps and reclaims expired Card Leases (``ExpiredLeaseSweep``, loop-state/reclaim-an-expired-
///    lease, P8.10), then reconciles Worktrees (``WorktreeReconciler``), then reposts board state from
///    the Journal (``BoardStateProjection/repost()``) — the board projection is resolved once, when a
///    Board is bound, and handed to both.
/// 2. Performs the Delta Read (``DeltaRead``). Cancelled is applied inside the Delta Read itself; edits
///    and human comments ride in its report for later phases to consume.
/// 3. Derives Repo Lanes from the in-flight Feature's Cards, read fresh from the Journal after the
///    Delta Read, so Cancelled Cards (and a reclaimed Card's return to Ready) are already reflected.
/// 4. Runs lanes concurrently, and each lane's Cards one at a time in authored order, through an
///    injectable ``CardRunner`` (the per-Card run itself is P8.4, a later phase) — a Crashed-Unknown
///    reclaim retries its Card's same Route once in this very pass, since the Card is back in Todo and
///    that ending never excludes a Route.
/// 5. Writes back (delivers pending Outbox entries) and returns; the invocation records `ActEnded` and
///    releases the lease.
///
/// A forced build with no Feature in flight, or whose in-flight Cycle already landed (roadmap P10.1;
/// risks OQ8, once per Cycle), fires but does no work: it appends `.actIdle` and returns, because
/// `EngineInvocation` only guards these when the trigger is not forced. Once a Cycle has landed, this
/// Act never reads the board again for a Card left Waiting on You in it — the author Act's own
/// ``PostLandingReplies`` step (roadmap P11.3) does that instead, since only it still fires.
public struct BuildAct: Sendable {
    public let cardRunner: any CardRunner
    /// The Readiness Check run before each Card is dispatched (P8.2); nil keeps the lane's pre-P8.2
    /// behaviour of dispatching every runnable Card unchecked, which is what tests that predate P8.2
    /// still exercise.
    public let readiness: ReadinessCheck?
    /// Locates a dead run's last-attempted pass's result file for the lease-reclaim sweep's defensive
    /// classification (P8.10); nil falls to the event log and Crashed-Unknown, which is what a rehearsal
    /// Night's own binding does too (it writes no result files) and what every pre-P8.10 test exercises.
    public let resultReader: (any RunResultReading)?
    /// The Pre-Reclaim Quiescence Gate the lease-reclaim sweep runs before classifying or reposting a
    /// reclaimed Card (P8.10).
    public let worktreeFencer: ProcessFencer
    /// The most Nights a Card's outstanding question may go unanswered (`unanswered_nights_max`),
    /// shared with the Refusal and Authoring Halt clocks: the Silence countdown a remark's
    /// acknowledgement reports (roadmap P11.2) reads it too. Required in production
    /// (`RootCommand` passes `project.bounds.unansweredNightsMax`); the ruled default of 3 is what
    /// every test that predates P11.2 still exercises.
    public let unansweredNightsMax: Int

    public init(
        cardRunner: any CardRunner,
        readiness: ReadinessCheck? = nil,
        resultReader: (any RunResultReading)? = nil,
        worktreeFencer: ProcessFencer = ProcessFencer(),
        unansweredNightsMax: Int = 3
    ) {
        self.cardRunner = cardRunner
        self.readiness = readiness
        self.resultReader = resultReader
        self.worktreeFencer = worktreeFencer
        self.unansweredNightsMax = unansweredNightsMax
    }

    public var work: EngineInvocation.ActWork {
        { context in try await self.run(context) }
    }

    public func run(_ context: ActContext) async throws {
        let journal = context.journal
        guard let (feature, cycleID) = try journal.inFlightFeature() else {
            try journal.append(
                .actIdle(reason: .noFeatureInFlight), act: context.act, runID: context.runID, nightID: context.night.id
            )
            return
        }
        if try journal.isCycleLanded(cycleID: cycleID) {
            try journal.append(
                .actIdle(reason: .cycleAlreadyLanded), act: context.act, runID: context.runID, nightID: context.night.id
            )
            return
        }

        let projection = try await resolveBoardProjection(context: context)

        _ = try await ExpiredLeaseSweep(
            journal: journal, runID: context.runID, act: context.act, nightID: context.night.id,
            fencer: worktreeFencer, projection: projection, resultReader: resultReader
        ).sweep(featureID: feature.id, cycleID: cycleID)

        let reconciliation = try await reconcileWorktrees(feature: feature, context: context)

        try await repostBoardState(projection: projection, context: context)

        switch try await performDeltaRead(context: context) {
        case .degraded?:
            // The Delta Read already recorded the degradation; the build Act does less work and does
            // not derive or run lanes on top of a read that could not complete. It still writes back
            // what earlier steps accepted into the Outbox.
            break
        case .read(let report)?:
            try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: unansweredNightsMax)
            try await UnansweredCardClock.run(
                cycleIDs: [cycleID], unansweredNightsMax: unansweredNightsMax, context: context
            )
            try await runLanes(
                feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: report, context: context
            )
        case nil:
            // No Board bound: nothing to read, but the clock is still spent by the Night this Act ran.
            try await UnansweredCardClock.run(
                cycleIDs: [cycleID], unansweredNightsMax: unansweredNightsMax, context: context
            )
            try await runLanes(
                feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: nil, context: context
            )
        }
        try await writeBack(context: context)
    }

    // MARK: - Worktree reconciliation

    private func reconcileWorktrees(
        feature: FeatureRecord, context: ActContext
    ) async throws -> WorktreeReconciliation {
        let held = try context.journal.worktrees(featureID: feature.id).filter(\.isHeld)
        guard !held.isEmpty else { return WorktreeReconciliation() }
        guard let workspace = context.workspace else {
            throw BuildActError.workspaceRequired(featureID: feature.id)
        }
        guard let branch = feature.branch else {
            throw BuildActError.featureBranchUnrecorded(featureID: feature.id)
        }
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: context.journal, runID: context.runID, act: context.act,
            nightID: context.night.id, committer: WorktreeCommitter(mode: context.mode)
        )
        return try await reconciler.reconcile(featureID: feature.id, branch: branch)
    }

    // MARK: - Board repost

    /// Resolved once, when a Board is bound, and shared by the lease-reclaim sweep (P8.10) and the
    /// repost below: both write through the same projection, over the same resolved scope.
    private func resolveBoardProjection(context: ActContext) async throws -> BoardStateProjection? {
        guard let board = context.board, let outbox = context.outbox else { return nil }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        return BoardStateProjection(journal: context.journal, outbox: outbox, scope: scope)
    }

    private func repostBoardState(projection: BoardStateProjection?, context: ActContext) async throws {
        guard let projection else { return }
        let outcomes = try await projection.repost()
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

    // MARK: - Delta Read

    private func performDeltaRead(context: ActContext) async throws -> DeltaReadOutcome? {
        guard let board = context.board else { return nil }
        let read = DeltaRead(
            journal: context.journal, board: board.reading, runID: context.runID, act: context.act,
            nightID: context.night.id, repositories: nil
        )
        return try await read.perform()
    }

    // MARK: - Lanes

    private func runLanes(
        feature: FeatureRecord, cycleID: Int64, reconciliation: WorktreeReconciliation,
        deltaRead: DeltaReadReport?, context: ActContext
    ) async throws {
        let cards = try context.journal.cards(cycleID: cycleID)
        let lanes = RepoLane.derive(from: cards)
        try context.journal.append(
            .repoLanesDerived(cycleID: cycleID, lanes: lanes.map(\.repository)),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        let buildContext = BuildActContext(
            act: context, feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: deltaRead
        )

        var failures: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for lane in lanes {
                group.addTask {
                    await self.run(lane: lane, context: buildContext, actContext: context)
                }
            }
            for await (repository, failure) in group {
                if let failure {
                    failures[repository] = failure
                }
            }
        }

        if !failures.isEmpty {
            throw BuildActError.lanesFailed(failures)
        }
    }

    /// One lane, start to end, appending its own started/ended events. Never throws: an engine fault
    /// from `cardRunner` is caught, recorded as this lane's failure, and returned to the caller so
    /// other lanes are never cancelled by it.
    private func run(lane: RepoLane, context: BuildActContext, actContext: ActContext) async -> (String, String?) {
        let runnable = lane.runnable
        _ = try? actContext.journal.append(
            .repoLaneStarted(repository: lane.repository, cards: runnable.count),
            act: actContext.act, runID: actContext.runID, nightID: actContext.night.id
        )

        var cardsRun = 0
        var cardsSkipped = 0
        var failure: String?
        for card in runnable {
            do {
                let cardReadiness: CardReadiness
                if let readiness {
                    switch try await readiness.evaluate(card: card, context: context) {
                    case .ready(let ready):
                        cardReadiness = ready
                    case .notReady, .diverged, .refused:
                        cardsSkipped += 1
                        continue
                    }
                } else {
                    cardReadiness = CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
                }
                try await cardRunner.run(card: card, in: lane, context: context, readiness: cardReadiness)
                cardsRun += 1
                try recordLaneHoleIfNeeded(cardID: card.id, repository: lane.repository, actContext: actContext)
            } catch {
                failure = String(describing: error)
                break
            }
        }

        _ = try? actContext.journal.append(
            .repoLaneEnded(
                repository: lane.repository, cardsRun: cardsRun, failure: failure, cardsSkipped: cardsSkipped
            ),
            act: actContext.act, runID: actContext.runID, nightID: actContext.night.id
        )
        return (lane.repository, failure)
    }

    /// Re-reads a Card just run and, when it is now Blocked or Waiting on You, appends
    /// `.laneHoleRecorded` (graph-execution/handle-a-block-mid-graph, P8.9): the lane already moved on
    /// to its next Card, so this only names the hole for the Partial Landing announcement (P10.4) to
    /// read later, via ``JournalStore/laneHoles(cycleID:)``.
    private func recordLaneHoleIfNeeded(cardID: Int64, repository: String, actContext: ActContext) throws {
        let current = try actContext.journal.card(id: cardID)
        switch current.state {
        case .blocked, .waitingOnYou:
            try actContext.journal.append(
                .laneHoleRecorded(
                    cardID: current.id, issueID: current.issueID, repository: repository, state: current.state
                ),
                act: actContext.act, runID: actContext.runID, nightID: actContext.night.id
            )
        default:
            break
        }
    }

    // MARK: - Write back

    private func writeBack(context: ActContext) async throws {
        guard let outbox = context.outbox else { return }
        _ = try await outbox.deliverPending()
    }
}

public enum BuildActError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Held Worktrees exist for this Feature but the Journal has no Feature Branch recorded for it.
    case featureBranchUnrecorded(featureID: Int64)
    /// Held Worktrees exist for this Feature but this invocation was given no Workspace Port.
    case workspaceRequired(featureID: Int64)
    /// At least one Repo Lane's runner threw; every lane ran to completion or failure before this was
    /// thrown. Keyed by repository.
    case lanesFailed([String: String])

    public var description: String {
        switch self {
        case .featureBranchUnrecorded(let featureID):
            return "Feature \(featureID) holds a Worktree but the Journal has no Feature Branch recorded for it"
        case .workspaceRequired(let featureID):
            return "Feature \(featureID) holds a Worktree but this invocation was given no Workspace Port"
        case .lanesFailed(let failures):
            let named = failures.keys.sorted().map { "\($0): \(failures[$0]!)" }.joined(separator: "; ")
            return "the build Act's lanes failed: \(named)"
        }
    }
}
