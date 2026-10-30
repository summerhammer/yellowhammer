import Domain
import Foundation
import Journal
import Repositories

/// Reads what a lane's remote Feature Branch is at, right before its pull request opens (OQ191 item 4). Local
/// git, not the Publication Port: ``git(reader:credential:)`` is the land Act's real read.
public struct RemoteFeatureBranchRead: Sendable {
    let read: @Sendable (_ branch: FeatureBranch, _ repositoryPath: String) async -> RemoteFeatureBranchTip

    public init(
        read: @escaping @Sendable (_ branch: FeatureBranch, _ repositoryPath: String) async -> RemoteFeatureBranchTip
    ) {
        self.read = read
    }

    /// `git ls-remote` with the push's credential, resolved on each read, as ``FeatureBranchLanePush`` resolves
    /// it. A credential that cannot be resolved reads as unreadable, so it is a failed publication.
    public static func git(
        reader: RemoteFeatureBranchReader = RemoteFeatureBranchReader(),
        credential: @escaping @Sendable () throws -> PushCredential?
    ) -> RemoteFeatureBranchRead {
        RemoteFeatureBranchRead { branch, path in
            let resolved: PushCredential?
            do {
                resolved = try credential()
            } catch {
                return .unreadable(reason: "GitHub credentials could not be resolved")
            }
            return await reader.read(branch: branch, in: path, credential: resolved)
        }
    }
}

// The remote tip check (OQ191 item 4; landing/open-one-pull-request-per-repository `#remote-tip-check`): before
// every pull request open — the first land firing right after its own push, and every retry — the remote
// Feature Branch is read. At the Pushed Tip, the pull request opens. At another commit, absent, or unreadable,
// it does not: the open-pull-request step fails, the lane's Worktree stays held, the Cycle stays unlanded, and
// the next land firing checks again. The other lanes still publish and release in that firing (OQ194, the
// Operator's decision as built). The failure is a Journal event, a comment on the Feature Card and on each Work
// Card of the lane, and the failed land step's detail, which the Night Summary counts as a failed landing step.

extension FeatureBranchPullRequest {
    /// Nil when the remote Feature Branch is at the Pushed Tip, so the pull request may open; else the outcome
    /// that keeps it from opening, already reported.
    func checkRemoteTip(
        _ context: LandActLaneContext, branch: FeatureBranch, repositoryPath: String, push: LanePushOutcome
    ) async -> PullRequestOutcome? {
        let repository = context.lane.repository
        // The Pushed Tip the land Act recorded for this Cycle; the push's own commit, the same commit (A1), when
        // a caller opens without a recorded one.
        let recorded = try? context.act.journal.pushedTip(cycleID: context.cycleID, repository: repository)
        guard let pushedTip = recorded ?? push.commit else {
            return await fail("no Pushed Tip is recorded for `\(repository)`", laneContext: context)
        }

        let failure: RemoteTipFailure
        switch await remoteTip.read(branch, repositoryPath) {
        case .at(let commit) where commit == pushedTip:
            return nil
        case .at(let commit):
            failure = RemoteTipFailure(
                text: "Not landed: the remote branch `\(branch.name)` in \(repository) is at "
                    + "\(GitCommit.short(commit)), not at the Pushed Tip \(GitCommit.short(pushedTip)). "
                    + "No pull request was opened for \(repository).",
                event: .remoteTipMismatch(repository: repository, pushedTip: pushedTip, remoteCommit: commit),
                key: "remote-tip-mismatch:\(commit)"
            )
        case .absent:
            failure = RemoteTipFailure(
                text: "Not landed: the remote branch `\(branch.name)` in \(repository) is absent; the Pushed Tip is "
                    + "\(GitCommit.short(pushedTip)). No pull request was opened for \(repository).",
                event: .remoteTipMismatch(repository: repository, pushedTip: pushedTip, remoteCommit: nil),
                key: "remote-tip-mismatch:absent"
            )
        case .unreadable(let reason):
            failure = RemoteTipFailure(
                text: "Not landed: the remote branch `\(branch.name)` in \(repository) could not be read "
                    + "(\(reason)). The next land firing retries.",
                event: .remoteTipUnreadable(repository: repository, reason: reason),
                key: "remote-tip-unreadable"
            )
        }

        let act = context.act
        _ = try? act.journal.append(failure.event, act: act.act, runID: act.runID, nightID: act.night.id)
        await postRemoteTipFailure(failure.text, keySuffix: failure.key, laneContext: context)
        return PullRequestOutcome(opened: false, detail: failure.text)
    }

    /// The failure on the Feature Card and on each Work Card of the lane. One key per Cycle, repository and remote
    /// state: a firing that finds the same state posts nothing again.
    private func postRemoteTipFailure(_ body: String, keySuffix: String, laneContext: LandActLaneContext) async {
        let placement = LandCommentPlacement(
            cycleID: laneContext.cycleID, repository: laneContext.lane.repository,
            featureIssueID: laneContext.feature.issueID, laneCards: laneContext.lane.cards
        )
        await placement.post(body, keySuffix: keySuffix, outbox: laneContext.act.outbox)
    }
}

/// What the remote tip check reports when the pull request does not open: the Operator's text, the Journal event,
/// and the Outbox key suffix for the remote state it found.
private struct RemoteTipFailure {
    let text: String
    let event: JournalEvent
    let key: String
}
