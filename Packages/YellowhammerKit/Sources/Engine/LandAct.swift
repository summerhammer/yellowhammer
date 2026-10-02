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
/// 3. Repo Lanes are derived from the Cycle's Cards. In a first phase each runs, sequentially, its merge
///    test (P10.3) and push (P10.2). `context.mode == .rehearsal` is a rehearsal boundary enforced here,
///    in defence in depth: the push and open-pull-request seams are never called, and those two steps
///    are recorded `.rehearsalBoundary`. The merge test still runs in rehearsal — pure local git. A lane
///    whose seam throws is an engine fault: recorded, the lane's remaining steps are skipped, and the
///    other lanes still run. A lane whose push reports no completed work has its No-Pushed-Branch Outcome
///    recorded once (a record that cannot be written faults the lane); so does every touched repository no
///    Card names, which has no lane and no push step, in rehearsal mode too.
/// 4. If no lane faulted: Verification (P10.5), judged before any pull request exists because a pull
///    request body is written once and carries its clause report. A rehearsal Night runs it too — its
///    verifier is answered by a fixture, never an agent CLI. A nil Verification seam records all three
///    Feature steps `.notWired` and gates nothing.
/// 5. In a second phase each lane that did not fault opens its pull request (P10.4) and then releases its
///    held Worktree. Where Verification is wired but did not complete — a lane faulted in the first
///    phase, or Verification itself did — every lane's pull request is recorded `.skipped` and its
///    Worktree stays held; the Cycle stays unlanded and the next land firing retries.
/// 6. If nothing faulted, by Verification's verdict: return the Feature (P10.6) or archive the Cycle
///    (P10.7), never both. When every touched repository has the outcome (N = 0) no pull request opened
///    and the Feature is not Done: an all-met verdict does not archive the Cycle, which still lands.
/// 7. If nothing faulted: the Cycle is marked landed. Write-back always runs, fault or not: it replays
///    any deferred Card state write left behind (``DeferredCardStateReplay``, issue #96 — this
///    Act dispatches no Card, so nothing else ever retries one) and then delivers the Outbox. A fault
///    (from any lane or the Feature sequence) is thrown after write-back as
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
    /// Runs Verification over the Feature (P10.5), after the lanes' push and before any pull request; nil
    /// records `.notWired` for all three Feature steps.
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
        var progresses: [LandLaneProgress] = []
        for lane in lanes {
            let progress = await runFirstPhase(lane: lane, feature: feature, cycleID: cycleID, context: context)
            progress.fault.map { failures[lane.repository] = $0 }
            progresses.append(progress)
        }

        failures.merge(
            recordLanelessOutcomes(lanes: lanes, feature: feature, cycleID: cycleID, context: context)
        ) { $1 }

        let verification = await runVerification(
            feature: feature, cycleID: cycleID, firstPhaseFailed: !failures.isEmpty, context: context
        )
        if case .faulted(let failure) = verification {
            failures[feature.issueID] = failure
        }
        failures.merge(await runSecondPhases(progresses, gate: verification.gate, context: context)) { $1 }

        if failures.isEmpty {
            let fault = await runFeatureSteps(
                verification: verification, feature: feature, cycleID: cycleID, context: context
            )
            fault.map { failures[feature.issueID] = $0 }
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

    /// Replays any Card state write deferred and left behind (``DeferredCardStateReplay``, roadmap
    /// issue #96 — this Act dispatches no Card, so nothing else ever retries one), then delivers pending
    /// Outbox entries.
    private func writeBack(context: ActContext) async throws {
        try await DeferredCardStateReplay.run(context: context)
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
