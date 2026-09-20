import Domain
import Journal

// Reporting a Repo Lane push's outcome (P10.2): the land step it records, and the board comments it
// posts through the Outbox. Split out of LandAct+LaneSteps.swift to keep that file under the file
// length limit.

extension LandAct {
    /// The land step this push outcome records. `.noCompletedWork` is recorded skipped, not failed —
    /// there was nothing to push, not a failure to push it.
    func pushStepResult(for outcome: LanePushOutcome) -> LandStepResult {
        switch outcome.kind {
        case .pushed(let commit):
            return .completed(detail: commit)
        case .noCompletedWork:
            return .skipped("no completed work")
        case .refusedByBranchProtection, .credentialsMissingOrInsufficient, .refusedMainline, .failed:
            return .failed(outcome.reason)
        }
    }

    /// Posts this push's outcome to the board, through the Outbox when one is bound. A pushed commit
    /// gets one comment on each `.done` Card of the lane; every refusal or failure gets one comment on
    /// the Feature Issue naming the repository, the Feature Branch, and what happened. `.noCompletedWork`
    /// posts nothing — it is not a fault, and the pull request step is then skipped as "not pushed". An
    /// Outbox post failure is best-effort here and must never fault the lane.
    func recordPushOutcome(_ outcome: LanePushOutcome, laneContext: LandActLaneContext, context: ActContext) async {
        switch outcome.kind {
        case .pushed(let commit):
            await postPushedComments(commit: commit, laneContext: laneContext, context: context)
        case .noCompletedWork:
            return
        case .refusedByBranchProtection, .credentialsMissingOrInsufficient, .refusedMainline, .failed:
            await postPushFailureComment(outcome: outcome, laneContext: laneContext, context: context)
        }
    }

    private func postPushedComments(commit: String, laneContext: LandActLaneContext, context: ActContext) async {
        guard let outbox = context.outbox else { return }
        let repository = laneContext.lane.repository
        let branchName = laneContext.feature.branch?.name ?? repository
        let body = "Pushed Feature Branch `\(branchName)` for `\(repository)` at `\(commit)`."
        for card in laneContext.lane.cards where card.state == .done {
            let key = "land:\(laneContext.cycleID):\(repository):push:\(card.issueID)"
            let write = OutboxWrite(
                key: key, write: .createComment(issue: BoardObjectID(rawValue: card.issueID), body: body)
            )
            _ = try? await outbox.post(write)
        }
    }

    private func postPushFailureComment(
        outcome: LanePushOutcome, laneContext: LandActLaneContext, context: ActContext
    ) async {
        guard let outbox = context.outbox else { return }
        let repository = laneContext.lane.repository
        let branchName = laneContext.feature.branch?.name ?? repository
        let body = "The push of Feature Branch `\(branchName)` for repository `\(repository)` did not "
            + "complete: \(pushFailureWording(for: outcome))"
        let key = "land:\(laneContext.cycleID):\(repository):push-failed"
        let write = OutboxWrite(
            key: key,
            write: .createComment(issue: BoardObjectID(rawValue: laneContext.feature.issueID), body: body)
        )
        _ = try? await outbox.post(write)
    }

    private func pushFailureWording(for outcome: LanePushOutcome) -> String {
        switch outcome.kind {
        case .refusedByBranchProtection(let detail):
            return "GitHub branch protection refused the push. \(detail)"
        case .credentialsMissingOrInsufficient(let detail):
            return "GitHub credentials are missing or insufficient. \(detail)"
        case .refusedMainline:
            return "the Feature Branch is the repository's Mainline; it was refused."
        case .failed(let reason):
            return reason
        case .pushed, .noCompletedWork:
            return ""
        }
    }
}
