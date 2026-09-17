import Domain
import Foundation
import Journal

/// The build Act's work (roadmap P8.1; spec: graph-execution/overview,
/// shift-scheduling/fire-an-act-on-schedule), in this order:
///
/// 1. Sweeps expired Card Leases (``ExpiredLeaseSweep``, the Journal half of P8.10), then reconciles
///    Worktrees (``WorktreeReconciler``), then reposts board state from the Journal
///    (``BoardStateProjection/repost()``).
/// 2. Performs the Delta Read (``DeltaRead``). Cancelled is applied inside the Delta Read itself; edits
///    and human comments ride in its report for later phases to consume.
/// 3. Derives Repo Lanes from the in-flight Feature's Cards, read fresh from the Journal after the
///    Delta Read, so Cancelled Cards are already reflected.
/// 4. Runs lanes concurrently, and each lane's Cards one at a time in authored order, through an
///    injectable ``CardRunner`` (the per-Card run itself is P8.4, a later phase).
/// 5. Writes back (delivers pending Outbox entries) and returns; the invocation records `ActEnded` and
///    releases the lease.
///
/// A forced build with no Feature in flight fires but does no work: it appends `.actIdle` and returns,
/// because `EngineInvocation` only guards this when the trigger is not forced.
public struct BuildAct: Sendable {
    public let cardRunner: any CardRunner

    public init(cardRunner: any CardRunner) {
        self.cardRunner = cardRunner
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

        _ = try ExpiredLeaseSweep(journal: journal, runID: context.runID, act: context.act, nightID: context.night.id)
            .sweep(cycleID: cycleID)

        let reconciliation = try await reconcileWorktrees(feature: feature, context: context)

        try await repostBoardState(context: context)

        switch try await performDeltaRead(context: context) {
        case .degraded?:
            // The Delta Read already recorded the degradation; the build Act does less work and does
            // not derive or run lanes on top of a read that could not complete. It still writes back
            // what earlier steps accepted into the Outbox.
            break
        case .read(let report)?:
            try await runLanes(
                feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: report, context: context
            )
        case nil:
            // No Board bound: nothing to read, so the lanes run without a report.
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
            nightID: context.night.id
        )
        return try await reconciler.reconcile(featureID: feature.id, branch: branch)
    }

    // MARK: - Board repost

    private func repostBoardState(context: ActContext) async throws {
        guard let board = context.board, let outbox = context.outbox else { return }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        let projection = BoardStateProjection(journal: context.journal, outbox: outbox, scope: scope)
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
        var failure: String?
        for card in runnable {
            do {
                try await cardRunner.run(card: card, in: lane, context: context)
                cardsRun += 1
            } catch {
                failure = String(describing: error)
                break
            }
        }

        _ = try? actContext.journal.append(
            .repoLaneEnded(repository: lane.repository, cardsRun: cardsRun, failure: failure),
            act: actContext.act, runID: actContext.runID, nightID: actContext.night.id
        )
        return (lane.repository, failure)
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
