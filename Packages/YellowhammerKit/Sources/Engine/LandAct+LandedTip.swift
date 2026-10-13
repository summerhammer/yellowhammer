import Domain
import Foundation
import Journal
import Repositories

// The land Act's record of a pushed tip (feature-authoring/select-the-next-feature, OQ164): the commit it
// pushed is recorded per (Feature, repository) in the Journal, then pinned at
// `refs/yellowhammer/landed/<branch>` in the repository's main clone, so the predecessor gate has a durable
// commit to test however the branch refs are later deleted.

extension LandAct {
    /// Records `commit` as the landed tip of the lane's repository, then pins it. The record comes first
    /// and throws — the Journal is what the gate reads, so a record that cannot be written faults the push
    /// step and the next land firing pushes again. A pin that cannot be written never throws and never
    /// changes the push: it is reported by a Journal-only ``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)``.
    func recordLandedTip(commit: String, laneContext: LandActLaneContext, context: ActContext) async throws {
        let feature = laneContext.feature
        let repository = laneContext.lane.repository
        try context.journal.recordLandedCommit(
            featureID: feature.id, repository: repository, commit: commit, runID: context.runID
        )

        guard let failure = await pinLandedTip(commit, feature: feature, repository: repository, context: context)
        else {
            return
        }
        _ = try? context.journal.append(
            .landedPinFailed(
                featureIssueID: feature.issueID, repository: repository, branch: failure.branch, commit: commit,
                operation: .pin, reason: failure.reason
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }

    /// Writes the pin in the repository's main clone; nil when git accepted it, else the branch and why not.
    private func pinLandedTip(
        _ commit: String, feature: FeatureRecord, repository: String, context: ActContext
    ) async -> (branch: String, reason: String)? {
        guard
            let branch = try? context.journal.resolvedFeatureBranch(feature: feature, repository: repository),
            let repo = context.repositories?.workingRepos.first(where: { $0.name == repository })
        else {
            return ("", "no Feature Branch or repository is configured to pin in")
        }
        let path = (repo.path as NSString).expandingTildeInPath
        guard case .failed(let reason) = await LandedTipPin().pin(commit: commit, branch: branch, repositoryPath: path)
        else {
            return nil
        }
        return (branch.name, reason)
    }
}

/// Deletes a Feature's landed pins when it becomes Abandoned — by the settle gesture or by Project removal.
/// Run after the Journal write that abandons the Feature, and never throws: a pin that cannot be deleted is
/// reported by a Journal-only ``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)``
/// and never fails the abandon. The landed commit stays recorded in the Journal. The next Card calls the same
/// ``LandedTipPin/unpin(branch:repositoryPath:)`` when an Observed Merge is recorded.
public struct LandedPinRelease: Sendable {
    private let pin: LandedTipPin
    private let act: Act?
    private let runID: RunID?
    private let nightID: Int64?

    /// `act`, `runID` and `nightID` stamp the failure event.
    public init(pin: LandedTipPin = LandedTipPin(), act: Act?, runID: RunID?, nightID: Int64?) {
        self.pin = pin
        self.act = act
        self.runID = runID
        self.nightID = nightID
    }

    /// Unpins every repository of `feature` with a landed commit, finding each clone in `repositories` by
    /// repository name. A repository whose clone is gone (a removed Project) has nothing to unpin and is not
    /// a failure.
    public func release(feature: FeatureRecord, repositories: [Repo], journal: JournalStore) async {
        guard let landed = try? journal.landedCommits(featureID: feature.id) else { return }
        for (repository, commit) in landed.sorted(by: { $0.key < $1.key }) {
            guard
                let repo = repositories.first(where: { $0.name == repository }),
                let branch = try? journal.resolvedFeatureBranch(feature: feature, repository: repository)
            else {
                continue
            }
            let path = (repo.path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard case .failed(let reason) = await pin.unpin(branch: branch, repositoryPath: path) else { continue }
            _ = try? journal.append(
                .landedPinFailed(
                    featureIssueID: feature.issueID, repository: repository, branch: branch.name,
                    commit: commit, operation: .unpin, reason: reason
                ),
                act: act, runID: runID, nightID: nightID
            )
        }
    }
}
