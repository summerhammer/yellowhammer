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
///    other lanes still run. A push that reports a refusal or failure (branch protection, missing or
///    insufficient credentials, a refused Mainline) is not a fault, but it leaves the push outstanding.
///    A lane whose push reports no completed work has its No-Pushed-Branch Outcome recorded once (a
///    record that cannot be written faults the lane); so does every touched repository no Card names,
///    which has no lane and no push step, in rehearsal mode too.
/// 4. If no lane faulted and no push is outstanding: Verification (P10.5), judged before any pull
///    request exists because a pull request body is written once and carries its clause report. A
///    rehearsal Night runs it too — its verifier is answered by a fixture, never an agent CLI. A nil
///    Verification seam records all three Feature steps `.notWired` and gates nothing.
/// 5. In a second phase each lane that did not fault opens its pull request (P10.4) and then releases its
///    held Worktree. While a push is outstanding, or where Verification is wired but did not complete
///    (a lane faulted in the first phase, or Verification itself did), every lane's pull request is
///    recorded `.skipped` and its Worktree stays held. A pull request the seam reports not opened is not
///    a fault either: it leaves that lane's Worktree held and the step outstanding; the lanes that did
///    open stay released.
/// 6. If nothing faulted and nothing is outstanding, by Verification's verdict: return the Feature
///    (P10.6) or archive the Cycle (P10.7), never both. When every touched repository has the outcome
///    (N = 0) no pull request opened and the Feature is not Done: an all-met verdict does not archive the
///    Cycle, which still lands.
/// 7. If nothing faulted and nothing is outstanding: the Cycle is marked landed. Otherwise it stays
///    unlanded, and the next land firing resumes the outstanding steps from the Journal's records: a
///    recorded Verification report is reused (``FeatureVerification``), a recorded pull request is not
///    opened again (``FeatureBranchPullRequest``), and a released Worktree is not released again.
///    Write-back always runs, fault or not: it replays any deferred Card state write left behind
///    (``DeferredCardStateReplay``, issue #96 — this Act dispatches no Card, so nothing else ever retries
///    one) and then delivers the Outbox. A fault (from any lane or the Feature sequence) is thrown after
///    write-back as ``LandActError/lanesFailed(_:)``, keyed by repository (Feature-scoped faults are keyed
///    by the Feature's issue id). An outstanding step alone is not thrown: the Act ends normally, with the
///    refusal already recorded as a failed land step and reported on the board.
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

        let progresses = await runFirstPhases(lanes: lanes, feature: feature, cycleID: cycleID, context: context)
        var failures = progresses.reduce(into: [String: String]()) { $0[$1.laneContext.lane.repository] = $1.fault }
        var outstanding = progresses.reduce(into: [String: String]()) {
            $0[$1.laneContext.lane.repository] = $1.outstandingPush
        }

        failures.merge(
            recordLanelessOutcomes(lanes: lanes, feature: feature, cycleID: cycleID, context: context)
        ) { $1 }

        let verification = await runVerification(
            feature: feature, cycleID: cycleID, firstPhaseIncomplete: !failures.isEmpty || !outstanding.isEmpty,
            context: context
        )
        if case .faulted(let failure) = verification {
            failures[feature.issueID] = failure
        }
        let gate = outstanding.isEmpty ? verification.gate : "a required push is outstanding"
        let secondPhases = await runSecondPhases(progresses, gate: gate, context: context)
        failures.merge(secondPhases.failures) { $1 }
        outstanding.merge(secondPhases.outstanding) { $1 }

        if failures.isEmpty, outstanding.isEmpty {
            let fault = await runFeatureSteps(
                verification: verification, feature: feature, cycleID: cycleID, context: context
            )
            fault.map { failures[feature.issueID] = $0 }
        }

        if failures.isEmpty, outstanding.isEmpty {
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
