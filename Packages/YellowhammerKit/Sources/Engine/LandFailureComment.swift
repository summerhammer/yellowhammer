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
