import Domain
import Foundation
import Journal
import Repositories

// The land Act's record of the Pushed Tip (feature-authoring/select-the-next-feature, `#pushed-tip`; OQ164,
// OQ191 item 2): the commit it pushed is recorded once per (Cycle, repository) in the Journal, then pinned at
// `refs/yellowhammer/landed/<branch>` in the repository's main clone, so the predecessor gate has a durable
// commit to test however the branch refs are later deleted.

extension LandAct {
    /// Records `commit` as the Pushed Tip of the lane's repository for this Cycle, then pins it. The record
    /// comes first and throws — the Journal is what the gate reads, so a record that cannot be written faults
    /// the push step and the next land firing pushes again. A Pushed Tip already recorded for the Cycle is never
    /// replaced, and then nothing is pinned again. A pin that cannot be written never throws and never changes
    /// the push: it is reported by a Journal-only ``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)``.
    func recordLandedTip(commit: String, laneContext: LandActLaneContext, context: ActContext) async throws {
        let feature = laneContext.feature
        let repository = laneContext.lane.repository
        let recorded = try context.journal.recordPushedTip(
            cycleID: laneContext.cycleID, repository: repository, commit: commit, runID: context.runID
        )
        guard recorded else { return }

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
/// and never fails the abandon. The Pushed Tip stays recorded in the Journal. The next Card calls the same
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

    /// Unpins every repository of `feature` with a Pushed Tip, finding each clone in `repositories` by
    /// repository name. A repository whose clone is gone (a removed Project) has nothing to unpin and is not
    /// a failure.
    public func release(feature: FeatureRecord, repositories: [Repo], journal: JournalStore) async {
        guard let landed = try? journal.pushedTips(featureID: feature.id) else { return }
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

    /// Deletes the landed pins `feature`'s recorded bases named whose deletion was deferred (spec:
    /// feature-authoring/select-the-next-feature, `#tested-tip`; agent rulings item 1): run after the Journal
    /// write that archives `feature`'s Cycle. A base stacked on a Feature that already has its Observed Merge in
    /// that repository had its pin kept only for this Cycle; it is deleted now unless another unarchived Cycle's
    /// base still names it. A pin whose Feature has not merged there stays: it is still that Feature's tested tip.
    /// Never throws; a pin that cannot be deleted is reported against the Feature that owns it, Journal-only.
    public func releaseBasePins(of feature: FeatureRecord, repositories: [Repo], journal: JournalStore) async {
        guard let bases = try? journal.featureBases(featureID: feature.id) else { return }
        for base in bases {
            guard
                let ownerID = base.stackedOnFeatureID,
                let owner = try? journal.feature(id: ownerID),
                let landings = try? journal.landings(featureID: ownerID), landings[base.repository] != nil,
                (try? journal.isBaseOfOpenCycle(repository: base.repository, baseRef: base.baseRef)) == false,
                let branch = Self.branch(pinnedAt: base.baseRef),
                let repo = repositories.first(where: { $0.name == base.repository })
            else {
                continue
            }
            let path = (repo.path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard case .failed(let reason) = await pin.unpin(branch: branch, repositoryPath: path) else { continue }
            let commit = (try? journal.pushedTips(featureID: ownerID))?[base.repository] ?? base.baseCommit
            _ = try? journal.append(
                .landedPinFailed(
                    featureIssueID: owner.issueID, repository: base.repository, branch: branch.name,
                    commit: commit, operation: .unpin, reason: reason
                ),
                act: act, runID: runID, nightID: nightID
            )
        }
    }

    /// The Feature Branch a `refs/yellowhammer/landed/<branch>` ref pins (``LandedTipPin/ref(for:)``); nil for any
    /// other ref, such as a mainline base.
    static func branch(pinnedAt ref: String) -> FeatureBranch? {
        let prefix = LandedTipPin.ref(for: FeatureBranch(rawValue: ""))
        guard ref.hasPrefix(prefix), ref.count > prefix.count else { return nil }
        return FeatureBranch(rawValue: String(ref.dropFirst(prefix.count)))
    }
}
