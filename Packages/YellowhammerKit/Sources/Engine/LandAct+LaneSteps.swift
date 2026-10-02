import Domain
import Journal

/// The outcome of one land step: what to record in the Journal, and whether it must stop the lane (or
/// the Feature-scoped sequence) as an engine fault.
struct LandStepResult {
    let outcome: LandStepOutcome
    let detail: String?
    /// Non-nil when this step's failure is an engine fault: the lane (or Feature sequence) stops here.
    let fault: String?

    static func completed(detail: String? = nil) -> LandStepResult {
        LandStepResult(outcome: .completed, detail: detail, fault: nil)
    }

    static func notWired() -> LandStepResult {
        LandStepResult(outcome: .notWired, detail: nil, fault: nil)
    }

    static func rehearsalBoundary() -> LandStepResult {
        LandStepResult(outcome: .rehearsalBoundary, detail: nil, fault: nil)
    }

    static func skipped(_ detail: String) -> LandStepResult {
        LandStepResult(outcome: .skipped, detail: detail, fault: nil)
    }

    /// A business-level failure the seam itself reported (not a throw): recorded, but the lane keeps
    /// going, e.g. a push seam that reports "not pushed".
    static func failed(_ detail: String?) -> LandStepResult {
        LandStepResult(outcome: .failed, detail: detail, fault: nil)
    }

    /// A seam that threw: an engine fault, recorded and stopping the lane (or Feature sequence).
    static func faulted(_ description: String) -> LandStepResult {
        LandStepResult(outcome: .failed, detail: description, fault: description)
    }
}

/// Where one Repo Lane stood after its first phase (merge test, push): carried to the second phase (open
/// pull request, release Worktree), which runs only once Verification has judged the Feature (P10.5).
struct LandLaneProgress {
    let laneContext: LandActLaneContext
    let mergeOutcome: MergeTestOutcome?
    let pushOutcome: LanePushOutcome?
    /// Non-nil when a seam of the first phase faulted: the lane stops there and skips its second phase.
    let fault: String?
}

extension LandAct {
    /// A Repo Lane's first phase: merge test, then push. Never throws: an engine fault from a seam is
    /// recorded as this lane's failure and carried in the result, so other lanes are never cancelled.
    func runFirstPhase(
        lane: RepoLane, feature: FeatureRecord, cycleID: Int64, context: ActContext
    ) async -> LandLaneProgress {
        let laneContext = LandActLaneContext(act: context, feature: feature, cycleID: cycleID, lane: lane)

        let (mergeResult, mergeOutcome) = await runMergeTest(laneContext)
        record(mergeResult, step: .mergeTest, repository: lane.repository, context: context)
        if let fault = mergeResult.fault {
            return LandLaneProgress(laneContext: laneContext, mergeOutcome: nil, pushOutcome: nil, fault: fault)
        }

        let (rawPushResult, pushOutcome) = await runPush(laneContext, context: context)
        let pushResult = recordingNoPushedBranchOutcome(
            rawPushResult, pushOutcome: pushOutcome, laneContext: laneContext, context: context
        )
        record(pushResult, step: .push, repository: lane.repository, context: context)
        return LandLaneProgress(
            laneContext: laneContext, mergeOutcome: mergeOutcome, pushOutcome: pushOutcome, fault: pushResult.fault
        )
    }

    /// One Repo Lane, both phases back to back with no Verification in between: merge test, push, open pull
    /// request, release Worktree. `run(_:)` does not use it; it lets a test exercise one lane's seams in
    /// isolation. Never throws: an engine fault is returned.
    func run(lane: RepoLane, feature: FeatureRecord, cycleID: Int64, context: ActContext) async -> String? {
        let progress = await runFirstPhase(lane: lane, feature: feature, cycleID: cycleID, context: context)
        if let fault = progress.fault { return fault }
        return await runSecondPhase(progress, verificationGate: nil, context: context)
    }

    /// Every lane's second phase, for the lanes whose first phase did not fault; the faults, by repository.
    func runSecondPhases(
        _ progresses: [LandLaneProgress], gate: String?, context: ActContext
    ) async -> [String: String] {
        var failures: [String: String] = [:]
        for progress in progresses where progress.fault == nil {
            let repository = progress.laneContext.lane.repository
            if let failure = await runSecondPhase(progress, verificationGate: gate, context: context) {
                failures[repository] = failure
            }
        }
        return failures
    }

    /// A Repo Lane's second phase: open pull request, then release the Worktree. `verificationGate`, when
    /// non-nil, is why Verification did not complete: the pull request is recorded skipped (its body is
    /// written once and must carry the clause report) and the Worktree is left held. Returns a fault
    /// description, nil otherwise.
    func runSecondPhase(
        _ progress: LandLaneProgress, verificationGate: String?, context: ActContext
    ) async -> String? {
        let laneContext = progress.laneContext
        let lane = laneContext.lane
        if let verificationGate {
            record(.skipped(verificationGate), step: .openPullRequest, repository: lane.repository, context: context)
            record(.skipped(verificationGate), step: .releaseWorktree, repository: lane.repository, context: context)
            return nil
        }

        let prResult = await runOpenPullRequest(
            laneContext, pushOutcome: progress.pushOutcome, mergeOutcome: progress.mergeOutcome, context: context
        )
        record(prResult, step: .openPullRequest, repository: lane.repository, context: context)
        if let fault = prResult.fault { return fault }

        let releaseResult = await runReleaseWorktree(
            feature: laneContext.feature, lane: lane, pushOutcome: progress.pushOutcome, context: context
        )
        record(releaseResult, step: .releaseWorktree, repository: lane.repository, context: context)
        return releaseResult.fault
    }

    private func runMergeTest(_ laneContext: LandActLaneContext) async -> (LandStepResult, MergeTestOutcome?) {
        guard let mergeTest else { return (.notWired(), nil) }
        do {
            let outcome = try await mergeTest.test(laneContext)
            return (.completed(detail: outcome.detail), outcome)
        } catch {
            return (.faulted(String(describing: error)), nil)
        }
    }

    /// Records the pushed commit on the lane's held Worktree, if any: this is the release gate
    /// ``JournalStore/releaseWorktree(id:runID:now:)`` and ``WorktreeAllocator/release(featureID:repository:)``
    /// check, so a push seam's own report of "pushed" must land here before release is attempted.
    /// Best-effort — a lane with no held Worktree recorded has nothing to update.
    private func recordPushedCommit(_ commit: String, laneContext: LandActLaneContext, context: ActContext) {
        guard
            let held = try? context.journal.heldWorktree(
                featureID: laneContext.feature.id, repository: laneContext.lane.repository
            ),
            held.isHeld
        else {
            return
        }
        _ = try? context.journal.recordWorktreePush(id: held.id, commit: commit, runID: context.runID)
    }

    /// Never called in rehearsal mode (a rehearsal boundary, defence in depth against dispatching a
    /// real push from a Rehearsal Night).
    private func runPush(
        _ laneContext: LandActLaneContext, context: ActContext
    ) async -> (LandStepResult, LanePushOutcome?) {
        if context.mode == .rehearsal {
            return (.rehearsalBoundary(), nil)
        }
        guard let push else {
            return (.notWired(), nil)
        }
        do {
            let outcome = try await push.push(laneContext)
            if outcome.pushed, let commit = outcome.commit {
                recordPushedCommit(commit, laneContext: laneContext, context: context)
            }
            await recordPushOutcome(outcome, laneContext: laneContext, context: context)
            return (pushStepResult(for: outcome), outcome)
        } catch {
            return (.faulted(String(describing: error)), nil)
        }
    }

    /// Never called in rehearsal mode, and never called for a lane whose push did not report pushed.
    private func runOpenPullRequest(
        _ laneContext: LandActLaneContext, pushOutcome: LanePushOutcome?, mergeOutcome: MergeTestOutcome?,
        context: ActContext
    ) async -> LandStepResult {
        if context.mode == .rehearsal {
            return .rehearsalBoundary()
        }
        guard let openPullRequest else {
            return .notWired()
        }
        guard let pushOutcome, pushOutcome.pushed else {
            return .skipped("not pushed")
        }
        do {
            let outcome = try await openPullRequest.open(laneContext, push: pushOutcome, mergeOutcome: mergeOutcome)
            return outcome.opened ? .completed(detail: outcome.detail) : .failed(outcome.detail)
        } catch {
            return .faulted(String(describing: error))
        }
    }

    /// Releases the lane's held Worktree, once its push reported pushed or safely skipped with no
    /// completed work (``JournalStore/releaseWorktree(id:runID:now:)``'s own refusal is defence in
    /// depth, not relied on here). Never throws for an unsafe push outcome — that is recorded skipped,
    /// and the Worktree stays held.
    private func runReleaseWorktree(
        feature: FeatureRecord, lane: RepoLane, pushOutcome: LanePushOutcome?, context: ActContext
    ) async -> LandStepResult {
        guard
            let held = try? context.journal.heldWorktree(featureID: feature.id, repository: lane.repository),
            held.isHeld
        else {
            return .skipped("no Worktree held")
        }
        guard let pushOutcome, pushOutcome.safeToReleaseWorktree else {
            return .skipped("not pushed")
        }
        guard let workspace = context.workspace else {
            return .skipped("no Workspace bound")
        }
        let allocator = WorktreeAllocator(workspace: workspace, journal: context.journal, runID: context.runID)
        do {
            _ = try await allocator.release(
                featureID: feature.id, repository: lane.repository, discardingUnpushedWork: !pushOutcome.pushed
            )
            return .completed()
        } catch {
            return .faulted(String(describing: error))
        }
    }

    func record(_ result: LandStepResult, step: LandStep, repository: String?, context: ActContext) {
        _ = try? context.journal.append(
            .landStep(step: step, repository: repository, outcome: result.outcome, detail: result.detail),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
