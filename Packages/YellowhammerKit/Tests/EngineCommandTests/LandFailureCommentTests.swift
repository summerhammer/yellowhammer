import Domain
@testable import Engine
import Testing

// Pin Failure item 2 (agent ruling 2026-11-02, pending sponsor review): the wording and keys of the comments a
// failed pin or a non-git directory posts at the land Act and at cancellation.

@Suite("LandFailureComment: wording and keys")
struct LandFailureCommentTests {
    private let commit = "0123456789abcdef0123456789abcdef01234567"

    @Test("pin failed, Worktree HEAD, land")
    func worktreeHeadLand() {
        let comment = LandFailureComment.pinFailed(
            subject: .worktreeHead, repository: "backend", reason: "cannot lock ref", recordedCommit: commit,
            moment: .land
        )
        #expect(comment.body == "Not landed: the Worktree's HEAD in `backend` could not be pinned before release. "
            + "Cause: git reported: cannot lock ref. The Worktree stays held and the Cycle is not landed; the next "
            + "land firing tries the pin again. Route out: fix what git names, and the next land firing pins it; "
            + "or save the commits under a branch of your own and put the Worktree's HEAD back at the recorded "
            + "commit 0123456, so that no pin is needed.")
    }

    @Test("a multi-line git reason reads as one paragraph, and the key hashes the raw reason")
    func multiLineReason() {
        let raw = "error: cannot lock ref 'refs/x'\nfatal:  update failed\n"
        let comment = LandFailureComment.pinFailed(
            subject: .worktreeHead, repository: "backend", reason: raw, recordedCommit: commit, moment: .land
        )
        #expect(comment.body.contains("Cause: git reported: error: cannot lock ref 'refs/x' fatal: update failed. "))
        #expect(!comment.body.contains("\n"))
        let flat = LandFailureComment.pinFailed(
            subject: .worktreeHead, repository: "backend",
            reason: LandFailureComment.oneParagraph(raw), recordedCommit: commit, moment: .land
        )
        #expect(comment.keySuffix != flat.keySuffix)
        #expect(comment.keySuffix == "pin-failed-land:" + String(ManagedBlockFence.sha256(raw).prefix(12)))
    }

    @Test("pin failed, Worktree HEAD, cancellation")
    func worktreeHeadCancellation() {
        let comment = LandFailureComment.pinFailed(
            subject: .worktreeHead, repository: "backend", reason: "cannot lock ref", recordedCommit: commit,
            moment: .cancellation
        )
        #expect(comment.body == "Not cancelled: the Worktree's HEAD in `backend` could not be pinned before "
            + "release. Cause: git reported: cannot lock ref. Every Worktree stays held, the Cycle is not archived "
            + "and no next Feature is selected; the next author firing tries the pin again. Route out: fix what "
            + "git names, and the next author firing pins it; or save the commits under a branch of your own and "
            + "put the Worktree's HEAD back at the recorded commit 0123456, so that no pin is needed.")
    }

    @Test("pin failed, Feature Branch in the main clone, land and cancellation")
    func featureBranch() {
        let land = LandFailureComment.pinFailed(
            subject: .featureBranch("yh/feature"), repository: "backend", reason: "boom", recordedCommit: commit,
            moment: .land
        )
        #expect(land.body == "Not landed: the Feature Branch `yh/feature` in the main clone of `backend` could not "
            + "be pinned before release. Cause: git reported: boom. The Worktree stays held and the Cycle is not "
            + "landed; the next land firing tries the pin again. Route out: fix what git names, and the next land "
            + "firing pins it; or save the commits under a branch of your own and move the Feature Branch back to "
            + "the recorded commit 0123456, so that no pin is needed.")
        let cancellation = LandFailureComment.pinFailed(
            subject: .featureBranch("yh/feature"), repository: "backend", reason: "boom", recordedCommit: commit,
            moment: .cancellation
        )
        #expect(cancellation.body.hasPrefix("Not cancelled: the Feature Branch `yh/feature` in the main clone of "
            + "`backend` could not be pinned before release. Cause: git reported: boom. Every Worktree stays held"))
        #expect(cancellation.body.hasSuffix("move the Feature Branch back to the recorded commit 0123456, "
            + "so that no pin is needed."))
    }

    @Test("pin failed without a recorded commit drops the second route")
    func noRecordedCommit() {
        let comment = LandFailureComment.pinFailed(
            subject: .worktreeHead, repository: "backend", reason: "boom", recordedCommit: nil, moment: .land
        )
        #expect(comment.body.hasSuffix("Route out: fix what git names, and the next land firing pins it."))
        #expect(!comment.body.contains("save the commits"))
    }

    @Test("not a git work tree, land, with and without a pin")
    func notGitLand() {
        let pinned = LandFailureComment.notGitWorktree(
            repository: "backend", path: "/wt/backend", pinRef: "refs/yellowhammer/unpublished/b", moment: .land
        )
        #expect(pinned.body == "Not landed: the Worktree directory for `backend` at `/wt/backend` is not a git work "
            + "tree, so its uncommitted changes cannot be saved. Its Feature Branch is pinned at "
            + "`refs/yellowhammer/unpublished/b`. The Worktree stays held and the Cycle is not landed; the next "
            + "land firing tries again. Route out: repair the directory so git can read it, or remove it \u{2014} "
            + "a removed directory is released on the next firing after its Feature Branch is pinned.")
        let unpinned = LandFailureComment.notGitWorktree(
            repository: "backend", path: "/wt/backend", pinRef: nil, moment: .land
        )
        #expect(!unpinned.body.contains("Its Feature Branch is pinned"))
        #expect(unpinned.body.contains("cannot be saved. The Worktree stays held"))
    }

    @Test("not a git work tree, cancellation")
    func notGitCancellation() {
        let comment = LandFailureComment.notGitWorktree(
            repository: "backend", path: "/wt/backend", pinRef: nil, moment: .cancellation
        )
        #expect(comment.body == "Not cancelled: the Worktree directory for `backend` at `/wt/backend` is not a git "
            + "work tree, so its uncommitted changes cannot be saved. Every Worktree stays held, the Cycle is not "
            + "archived and no next Feature is selected; the next author firing tries again. Route out: repair "
            + "the directory so git can read it, or remove it \u{2014} a removed directory is released on the next "
            + "firing after its Feature Branch is pinned.")
        #expect(!comment.body.lowercased().contains("cancel the"))
    }

    @Test("keys: same reason same key, different reason different key, moments differ")
    func keys() {
        func key(_ reason: String, _ moment: LandFailureComment.Moment) -> String {
            LandFailureComment.pinFailed(
                subject: .worktreeHead, repository: "backend", reason: reason, recordedCommit: nil, moment: moment
            ).keySuffix
        }
        #expect(key("a", .land) == key("a", .land))
        #expect(key("a", .land) != key("b", .land))
        #expect(key("a", .land) != key("a", .cancellation))
        #expect(key("a", .land).hasPrefix("pin-failed-land:"))
        #expect(key("a", .cancellation).hasPrefix("pin-failed-cancellation:"))
        #expect(key("a", .land).count == "pin-failed-land:".count + 12)
        let notGit = { (moment: LandFailureComment.Moment) in
            LandFailureComment.notGitWorktree(repository: "r", path: "/p", pinRef: nil, moment: moment).keySuffix
        }
        #expect(notGit(.land) == "worktree-not-git-land")
        #expect(notGit(.cancellation) == "worktree-not-git-cancellation")
    }
}
