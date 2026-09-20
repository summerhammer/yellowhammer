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

extension LandAct {
    /// One Repo Lane, start to end: merge test, push, open pull request, release Worktree, in that
    /// order. Never throws: an engine fault from a seam is recorded as this lane's failure and
    /// returned to the caller, so other lanes are never cancelled by it.
    func run(lane: RepoLane, feature: FeatureRecord, cycleID: Int64, context: ActContext) async -> String? {
        let laneContext = LandActLaneContext(act: context, feature: feature, cycleID: cycleID, lane: lane)

        let mergeResult = await runMergeTest(laneContext)
        record(mergeResult, step: .mergeTest, repository: lane.repository, context: context)
        if let fault = mergeResult.fault { return fault }

        let (pushResult, pushOutcome) = await runPush(laneContext, context: context)
        record(pushResult, step: .push, repository: lane.repository, context: context)
        if let fault = pushResult.fault { return fault }

        let prResult = await runOpenPullRequest(laneContext, pushOutcome: pushOutcome, context: context)
        record(prResult, step: .openPullRequest, repository: lane.repository, context: context)
        if let fault = prResult.fault { return fault }

        let releaseResult = await runReleaseWorktree(
            feature: feature, lane: lane, pushOutcome: pushOutcome, context: context
        )
        record(releaseResult, step: .releaseWorktree, repository: lane.repository, context: context)
        if let fault = releaseResult.fault { return fault }

        return nil
    }

    private func runMergeTest(_ laneContext: LandActLaneContext) async -> LandStepResult {
        guard let mergeTest else { return .notWired() }
        do {
            let outcome = try await mergeTest.test(laneContext)
            return .completed(detail: outcome.detail)
        } catch {
            return .faulted(String(describing: error))
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
            let result: LandStepResult = outcome.pushed ? .completed(detail: outcome.commit) : .failed(outcome.reason)
            return (result, outcome)
        } catch {
            return (.faulted(String(describing: error)), nil)
        }
    }

    /// Never called in rehearsal mode, and never called for a lane whose push did not report pushed.
    private func runOpenPullRequest(
        _ laneContext: LandActLaneContext, pushOutcome: LanePushOutcome?, context: ActContext
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
            let outcome = try await openPullRequest.open(laneContext, push: pushOutcome)
            return outcome.opened ? .completed(detail: outcome.detail) : .failed(outcome.detail)
        } catch {
            return .faulted(String(describing: error))
        }
    }

    /// Releases the lane's held Worktree, only once its push reported pushed
    /// (``JournalStore/releaseWorktree(id:runID:now:)``'s own refusal is defence in depth, not relied
    /// on here). Never throws for "not pushed" — that is recorded skipped, and the Worktree stays held.
    private func runReleaseWorktree(
        feature: FeatureRecord, lane: RepoLane, pushOutcome: LanePushOutcome?, context: ActContext
    ) async -> LandStepResult {
        guard
            let held = try? context.journal.heldWorktree(featureID: feature.id, repository: lane.repository),
            held.isHeld
        else {
            return .skipped("no Worktree held")
        }
        guard let pushOutcome, pushOutcome.pushed else {
            return .skipped("not pushed")
        }
        guard let workspace = context.workspace else {
            return .skipped("no Workspace bound")
        }
        let allocator = WorktreeAllocator(workspace: workspace, journal: context.journal, runID: context.runID)
        do {
            _ = try await allocator.release(featureID: feature.id, repository: lane.repository)
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
