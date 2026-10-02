import Domain
import Journal

// The land Act's record of the No-Pushed-Branch Outcome (glossary; risks OQ104, OQ107): a touched
// repository whose Repo Lane produced no completed work is never pushed and opens no pull request. It is
// recorded once, not a failure, and takes the repository out of N (``JournalStore/pushedRepositories(featureID:)``).

extension LandAct {
    /// Records the outcome for `repository` unless an outcome event for it already exists, superseded by a
    /// later push or not.
    /// Throws when the Journal cannot be read or written, so the caller can fault rather than land a Cycle
    /// whose outcome is missing.
    func recordNoPushedBranchOutcome(
        feature: FeatureRecord, cycleID: Int64, repository: String, context: ActContext
    ) throws {
        let journal = context.journal
        if try journal.hasNoPushedBranchOutcomeRecord(featureID: feature.id, repository: repository) { return }
        try journal.append(
            .noPushedBranchOutcome(cycleID: cycleID, featureIssueID: feature.issueID, repository: repository),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }

    /// A lane whose push reports no completed work has the outcome recorded; a record that cannot be
    /// written turns the push step into a fault, so the Cycle is not marked landed and the next firing
    /// retries. Any other result passes through unchanged.
    func recordingNoPushedBranchOutcome(
        _ pushResult: LandStepResult, pushOutcome: LanePushOutcome?, laneContext: LandActLaneContext,
        context: ActContext
    ) -> LandStepResult {
        guard let pushOutcome, case .noCompletedWork = pushOutcome.kind else { return pushResult }
        do {
            try recordNoPushedBranchOutcome(
                feature: laneContext.feature, cycleID: laneContext.cycleID,
                repository: laneContext.lane.repository, context: context
            )
            return pushResult
        } catch {
            return .faulted("could not record the No-Pushed-Branch Outcome: \(error)")
        }
    }

    /// Records the outcome for every touched repository no Card of the Cycle names, so no lane (and no push
    /// step) exists for it. No git read is needed: no Card ever ran there. Runs in rehearsal mode too, as
    /// no push step exists for such a repository in either mode. Returns the faults, by repository (or by
    /// the Feature's issue id when the touched repositories cannot be read).
    func recordLanelessOutcomes(
        lanes: [RepoLane], feature: FeatureRecord, cycleID: Int64, context: ActContext
    ) -> [String: String] {
        var failures: [String: String] = [:]
        let touched: [String]
        do {
            touched = try context.journal.touchedRepositories(featureID: feature.id)
        } catch {
            failures[feature.issueID] = String(describing: error)
            return failures
        }
        let laned = Set(lanes.map(\.repository))
        for repository in touched where !laned.contains(repository) {
            do {
                try recordNoPushedBranchOutcome(
                    feature: feature, cycleID: cycleID, repository: repository, context: context
                )
            } catch {
                failures[repository] = "could not record the No-Pushed-Branch Outcome: \(error)"
            }
        }
        return failures
    }
}
