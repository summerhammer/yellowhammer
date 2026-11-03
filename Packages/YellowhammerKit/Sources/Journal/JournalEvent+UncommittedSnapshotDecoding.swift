import Domain
import Foundation

// The uncommitted-changes snapshot event's payload and decoding (OQ196 item 1;
// landing/open-one-pull-request-per-repository `#uncommitted-snapshot`): the repository, the snapshot ref and commit,
// the counts of modified and untracked files, and whether it was taken at release or at cancellation. Enough to
// render the report again without git.

extension JournalEvent {
    static func decodeUncommittedSnapshot(_ reader: PayloadReader) throws -> JournalEvent {
        let moment = try reader.require("at")
        guard moment == "release" || moment == "cancellation" else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .uncommittedChangesSnapshotted(
            cycleID: try reader.int64("cycle_id"),
            snapshot: UncommittedChangesSnapshot(
                repository: try reader.require("repository"), ref: try reader.require("ref"),
                commit: try reader.require("commit"), modified: try reader.int("modified"),
                untracked: try reader.int("untracked"), atCancellation: moment == "cancellation"
            )
        )
    }

    var uncommittedSnapshotPayload: [String: String]? {
        guard case .uncommittedChangesSnapshotted(let cycleID, let snapshot) = self else { return nil }
        return [
            "cycle_id": String(cycleID), "repository": snapshot.repository, "ref": snapshot.ref,
            "commit": snapshot.commit, "modified": String(snapshot.modified), "untracked": String(snapshot.untracked),
            "at": snapshot.atCancellation ? "cancellation" : "release"
        ]
    }
}
