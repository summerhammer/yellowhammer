import Domain
import Foundation

// The unpublished-commits events' payload and decoding (OQ191 items 1, 2, 5, 6 and 9; OQ194 item 3;
// landing/open-one-pull-request-per-repository `#unpublished-commits-pin`): the repository, the recorded commit,
// HEAD and whether HEAD descends from the recorded commit, with how many commits after it, the no-pushed-branch
// mark and, once pinned, the pin ref. Enough to render the report again without git.

extension JournalEvent {
    /// Decodes `unpublishedCommitsReported`, `unpublishedCommitsPinned`, or
    /// `unpublishedCommitsPinnedAtCancellation`.
    static func decodeUnpublishedCommits(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        let descends = try reader.bool("descends")
        let unpublished = UnpublishedHead(
            repository: try reader.require("repository"), recordedCommit: try reader.require("recorded_commit"),
            head: try reader.require("head"), commitsAfter: descends ? try reader.int("commits_after") : nil,
            noPushedBranch: try reader.bool("no_pushed_branch")
        )
        let cycleID = try reader.int64("cycle_id")
        if type == .unpublishedCommitsReported {
            return .unpublishedCommitsReported(cycleID: cycleID, unpublished: unpublished)
        }
        let pinRef = try reader.require("pin_ref")
        if type == .unpublishedCommitsPinnedAtCancellation {
            return .unpublishedCommitsPinnedAtCancellation(cycleID: cycleID, unpublished: unpublished, pinRef: pinRef)
        }
        return .unpublishedCommitsPinned(cycleID: cycleID, unpublished: unpublished, pinRef: pinRef)
    }

    /// The `unpublishedCommitsReported`, `unpublishedCommitsPinned` and `unpublishedCommitsPinnedAtCancellation`
    /// events' payloads; `commits_after` is absent when HEAD does not descend from the recorded commit, and `pin_ref`
    /// when nothing is pinned yet.
    var unpublishedCommitsPayload: [String: String]? {
        let cycleID: Int64
        let unpublished: UnpublishedHead
        var pinRef: String?
        switch self {
        case .unpublishedCommitsReported(let reportedCycleID, let reported):
            (cycleID, unpublished) = (reportedCycleID, reported)
        case .unpublishedCommitsPinned(let pinnedCycleID, let pinned, let ref):
            (cycleID, unpublished, pinRef) = (pinnedCycleID, pinned, ref)
        case .unpublishedCommitsPinnedAtCancellation(let cancelledCycleID, let pinned, let ref):
            (cycleID, unpublished, pinRef) = (cancelledCycleID, pinned, ref)
        default:
            return nil
        }
        var payload = [
            "cycle_id": String(cycleID), "repository": unpublished.repository,
            "recorded_commit": unpublished.recordedCommit, "head": unpublished.head,
            "descends": unpublished.descends ? "true" : "false",
            "no_pushed_branch": unpublished.noPushedBranch ? "true" : "false"
        ]
        payload["commits_after"] = unpublished.commitsAfter.map(String.init)
        payload["pin_ref"] = pinRef
        return payload
    }
}
