import Domain
import Foundation
import Journal
import Repositories

/// What a failed pin was trying to pin.
enum PinSubject {
    /// The held Worktree's HEAD.
    case worktreeHead
    /// The Feature Branch in the main clone, for a gone or non-git Worktree directory.
    case featureBranch(FeatureBranch)
}

/// The board comment a failed pin before release posts, so the Operator is told the cause and a route out
/// (Pin Failure item 2). Four parts in order: headline, cause, details, route out. Posted once per Cycle,
/// repository, moment and text under a `land:` Outbox key.
enum LandFailureComment {
    enum Moment: String {
        case land
        case cancellation
    }

    /// git's reason as one paragraph: its stderr can run to several lines (`error:` then `fatal:`), and the
    /// comment and the Journal text are bounded to one paragraph. The key hashes the raw reason, so it stays
    /// once per reason.
    static func oneParagraph(_ reason: String) -> String {
        reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func journalReadFailed(
        repository: String, reason: String, moment: Moment
    ) -> (body: String, keySuffix: String) {
        let headline = moment == .land ? "Not landed" : "Not cancelled"
        let retry = moment == .land ? "land" : "author"
        let consequence = moment == .land
            ? "The Worktree stays held and the Cycle is not landed"
            : "Every Worktree stays held, the Cycle is not archived and no next Feature is selected"
        let body = "\(headline): the Journal could not be read before the pin in `\(repository)`. "
            + "Cause: \(oneParagraph(reason)). \(consequence); the next \(retry) firing tries again. "
            + "Route out: restore access to the Journal so the next \(retry) firing can read it before release."
        let digest = String(ManagedBlockFence.sha256(reason).prefix(12))
        return (body, "pin-journal-read-failed-\(moment.rawValue):\(digest)")
    }

    // draft-based: agent ruling 2026-11-02 item 2 (pins and landing failures), pending sponsor review
    static func pinFailed(
        subject: PinSubject, repository: String, reason: String, recordedCommit: String?, moment: Moment
    ) -> (body: String, keySuffix: String) {
        let subjectText: String
        let routeBack: String
        switch subject {
        case .worktreeHead:
            subjectText = "the Worktree's HEAD in `\(repository)`"
            routeBack = "put the Worktree's HEAD back at the recorded commit"
        case .featureBranch(let branch):
            subjectText = "the Feature Branch `\(branch.rawValue)` in the main clone of `\(repository)`"
            routeBack = "move the Feature Branch back to the recorded commit"
        }
        let headline: String
        let details: String
        let firing: String
        switch moment {
        case .land:
            headline = "Not landed"
            details = "The Worktree stays held and the Cycle is not landed; the next land firing tries the pin again."
            firing = "land"
        case .cancellation:
            headline = "Not cancelled"
            details = "Every Worktree stays held, the Cycle is not archived and no next Feature is selected; "
                + "the next author firing tries the pin again."
            firing = "author"
        }
        var route = "Route out: fix what git names, and the next \(firing) firing pins it"
        if let recordedCommit {
            route += "; or save the commits under a branch of your own and \(routeBack) "
                + "\(GitCommit.short(recordedCommit)), so that no pin is needed."
        } else {
            route += "."
        }
        let body = "\(headline): \(subjectText) could not be pinned before release. "
            + "Cause: git reported: \(oneParagraph(reason)). \(details) \(route)"
        let digest = String(ManagedBlockFence.sha256(reason).prefix(12))
        return (body, "pin-failed-\(moment.rawValue):\(digest)")
    }

    // draft-based: agent ruling 2026-11-02 item 2 shape, OQ196 item 1
    static func snapshotFailed(
        repository: String, reason: String, moment: Moment
    ) -> (body: String, keySuffix: String) {
        let cause = "Cause: git reported: \(oneParagraph(reason))."
        let body: String
        switch moment {
        case .land:
            body = "Not landed: the uncommitted changes in the Worktree for `\(repository)` could not be saved as a "
                + "snapshot before release. \(cause) The Worktree stays held and the Cycle is not landed; the next "
                + "land firing tries the snapshot again. \(snapshotRouteOut(firing: "land"))"
        case .cancellation:
            body = "Not cancelled: the uncommitted changes in the Worktree for `\(repository)` could not be saved "
                + "as a snapshot before release. \(cause) Every Worktree stays held, the Cycle is not archived and "
                + "no next Feature is selected; the next author firing tries the snapshot again. "
                + snapshotRouteOut(firing: "author")
        }
        let digest = String(ManagedBlockFence.sha256(reason).prefix(12))
        return (body, "snapshot-failed-\(moment.rawValue):\(digest)")
    }

    // draft-based: agent ruling 2026-11-02 item 2 shape, OQ196 item 1
    static func snapshotWithoutBranch(repository: String, moment: Moment) -> (body: String, keySuffix: String) {
        let route = "Route out: commit or discard the changes yourself, so that there is nothing to save."
        let body: String
        switch moment {
        case .land:
            body = "Not landed: the Worktree for `\(repository)` has uncommitted changes, and no Feature Branch is "
                + "recorded to save a snapshot under. The Worktree stays held and the Cycle is not landed; the next "
                + "land firing tries again. \(route)"
        case .cancellation:
            body = "Not cancelled: the Worktree for `\(repository)` has uncommitted changes, and no Feature Branch is "
                + "recorded to save a snapshot under. Every Worktree stays held, the Cycle is not archived and no "
                + "next Feature is selected; the next author firing tries again. \(route)"
        }
        return (body, "snapshot-no-branch-\(moment.rawValue)")
    }

    private static func snapshotRouteOut(firing: String) -> String {
        "Route out: fix what git names, and the next \(firing) firing saves it; "
            + "or commit or discard the changes yourself, so that there is nothing to save."
    }

    // draft-based: agent ruling 2026-11-02 item 2 (pins and landing failures), pending sponsor review
    static func notGitWorktree(
        repository: String, path: String, pinRef: String?, moment: Moment
    ) -> (body: String, keySuffix: String) {
        let headline: String
        let details: String
        switch moment {
        case .land:
            headline = "Not landed"
            details = "The Worktree stays held and the Cycle is not landed; the next land firing tries again."
        case .cancellation:
            headline = "Not cancelled"
            details = "Every Worktree stays held, the Cycle is not archived and no next Feature is selected; "
                + "the next author firing tries again."
        }
        var body = "\(headline): the Worktree directory for `\(repository)` at `\(path)` is not a git work tree, "
            + "so its uncommitted changes cannot be saved."
        if let pinRef {
            body += " Its Feature Branch is pinned at `\(pinRef)`."
        }
        body += " \(details) Route out: repair the directory so git can read it, or remove it \u{2014} "
            + "a removed directory is released on the next firing after its Feature Branch is pinned."
        return (body, "worktree-not-git-\(moment.rawValue)")
    }
}
