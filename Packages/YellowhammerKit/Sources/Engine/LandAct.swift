import Domain
import Foundation
import Journal
import Repositories

/// The land Act's sequencing skeleton (roadmap P10.1; spec: landing/overview, risks OQ8), modelled on
/// ``BuildAct``. `EngineInvocation` already opens (or joins) the Night and refreshes mainlines before
/// calling this Act's work — this does not redo either.
///
/// In order:
/// 1. No Feature in flight → `.actIdle(reason: .noFeatureInFlight)`, return (as `BuildAct` does, for
///    forced triggers — `EngineInvocation` only guards this when the trigger is not forced).
/// 2. The in-flight Cycle already landed → `.actIdle(reason: .cycleAlreadyLanded)`, return: a forced
///    land must not land the same Cycle twice.
/// 3. Repo Lanes are derived from the Cycle's Cards and run sequentially, one at a time: each lane's
///    merge test (P10.3), push (P10.2), open pull request (P10.4), then its held Worktree's release, in
///    that order. `context.mode == .rehearsal` is a rehearsal boundary enforced here, in defence in
///    depth: the push and open-pull-request seams are never called, and those two steps are recorded
///    `.rehearsalBoundary`. The merge test still runs in rehearsal — pure local git. A lane whose seam
///    throws is an engine fault: recorded, the lane's remaining steps are skipped, and the other lanes
///    still run.
/// 4. If no lane faulted: Verification (P10.5), then — by its verdict — return the Feature (P10.6) or
///    archive the Cycle (P10.7), never both. A nil Verification seam records all three steps
///    `.notWired` and calls neither.
/// 5. If nothing faulted: the Cycle is marked landed. The Outbox is always delivered, fault or not.
///    A fault (from any lane or the Feature sequence) is thrown after write-back as
///    ``LandActError/lanesFailed(_:)``, keyed by repository (Feature-scoped faults are keyed by the
///    Feature's issue id), so the Cycle stays unlanded and the next land firing retries.
public struct LandAct: Sendable {
    /// The Repo Lane merge test (P10.3); nil records `.notWired` and never gates landing.
    public let mergeTest: (any LaneMergeTesting)?
    /// The Repo Lane push (P10.2); nil records `.notWired`. Never called in rehearsal mode.
    public let push: (any LanePushing)?
    /// Opens a Repo Lane's pull request (P10.4); nil records `.notWired`. Never called in rehearsal
    /// mode, nor for a lane whose push did not report pushed.
    public let openPullRequest: (any PullRequestOpening)?
    /// Runs Verification over the Feature (P10.5); nil records `.notWired` for all three Feature steps.
    public let verification: (any FeatureVerifying)?
    /// Returns the Feature for unmet clauses (P10.6); nil records `.notWired`.
    public let returnFeature: (any FeatureReturning)?
    /// Archives the Feature's Cycle (P10.7); nil records `.notWired`.
    public let archiveCycle: (any CycleArchiving)?

    public init(
        mergeTest: (any LaneMergeTesting)? = nil,
        push: (any LanePushing)? = nil,
        openPullRequest: (any PullRequestOpening)? = nil,
        verification: (any FeatureVerifying)? = nil,
        returnFeature: (any FeatureReturning)? = nil,
        archiveCycle: (any CycleArchiving)? = nil
    ) {
        self.mergeTest = mergeTest
        self.push = push
        self.openPullRequest = openPullRequest
        self.verification = verification
        self.returnFeature = returnFeature
        self.archiveCycle = archiveCycle
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

        let lanes = RepoLane.derive(from: try journal.cards(cycleID: cycleID))

        var failures: [String: String] = [:]
        for lane in lanes {
            if let failure = await run(lane: lane, feature: feature, cycleID: cycleID, context: context) {
                failures[lane.repository] = failure
            }
        }

        if failures.isEmpty, let failure = await runFeatureSteps(feature: feature, cycleID: cycleID, context: context) {
            failures[feature.issueID] = failure
        }

        if failures.isEmpty {
            try journal.markCycleLanded(cycleID: cycleID, runID: context.runID)
            try journal.append(
                .cycleLanded(cycleID: cycleID), act: context.act, runID: context.runID, nightID: context.night.id
            )
        }

        try await writeBack(context: context)

        if !failures.isEmpty {
            throw LandActError.lanesFailed(failures)
        }
    }

    private func writeBack(context: ActContext) async throws {
        guard let outbox = context.outbox else { return }
        _ = try await outbox.deliverPending()
    }
}

public enum LandActError: Error, Equatable, Sendable, CustomStringConvertible {
    /// At least one Repo Lane's seam, or the Feature-scoped sequence, faulted. Keyed by repository, or
    /// by the Feature's issue id for a Feature-scoped fault.
    case lanesFailed([String: String])

    public var description: String {
        switch self {
        case .lanesFailed(let failures):
            let named = failures.keys.sorted().map { "\($0): \(failures[$0]!)" }.joined(separator: "; ")
            return "the land Act's lanes failed: \(named)"
        }
    }
}
