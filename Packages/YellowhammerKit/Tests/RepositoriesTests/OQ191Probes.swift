import Domain
import Foundation
import Testing

@testable import Repositories

// OQ191 (yellowhammer#708; spec ruling 2026-10-29, "a Cycle judges and publishes what it pushed"): the local git
// operations the land Act needs and `main` does not have yet. Each probe names the ruling item and the spec
// anchor it serves. Today each one returns nil; the implementation PRs replace the bodies with real calls and
// keep the signatures, so the tests do not change. Production code is untouched.

extension Tag {
    /// The OQ191 harness. Declared once per test target: each target is its own module.
    @Tag static var oq191: Self
}

/// What the remote Feature Branch is at, read before a pull request opens (item 4).
enum OQ191RemoteTip: Equatable {
    case at(String)
    case absent
    case unreadable
}

/// How a held Worktree's HEAD stands against its recorded commit (items 6 and 9).
enum OQ191HeadRelation: Equatable {
    case atRecordedCommit
    /// HEAD descends from the recorded commit, `commits` commits after it.
    case after(commits: Int, head: String)
    /// HEAD does not descend from the recorded commit: a rewritten branch.
    case differs(head: String)
}

/// What pinning a held Worktree's HEAD before release did (item 6).
enum OQ191PinResult: Equatable {
    /// HEAD was pinned at `ref`, a local ref outside `refs/heads/`.
    case pinned(ref: String)
    /// HEAD is the recorded commit: nothing to pin.
    case notNeeded
}

enum OQ191Probe {
    /// Item 4; `landing/stories/open-one-pull-request-per-repository.md#remote-tip-check`: the commit `branch` is
    /// at on the `origin` remote of the main clone at `repositoryPath`; `.absent` when the remote has no such
    /// branch; `.unreadable` when the remote cannot be read.
    static func remoteTip(branch: FeatureBranch, repositoryPath: String) async -> OQ191RemoteTip? {
        switch await RemoteFeatureBranchReader().read(branch: branch, in: repositoryPath, credential: nil) {
        case .at(let commit): .at(commit)
        case .absent: .absent
        case .unreadable: .unreadable
        }
    }

    /// Items 7 and 8; `verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout`: whether the
    /// held Worktree at `worktreePath` is exact (HEAD at `recordedCommit`) and clean (`git status` reports
    /// nothing; ignored files are allowed).
    static func isExactAndClean(worktreePath: String, recordedCommit: String) async -> Bool? {
        await JudgedCheckoutGit().isExactAndClean(worktreePath: worktreePath, recordedCommit: recordedCommit)
    }

    /// Items 6 and 9; `landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin`: how the
    /// held Worktree's HEAD stands against `recordedCommit` (the Pushed Tip or the recorded base commit).
    static func headRelation(worktreePath: String, recordedCommit: String) async -> OQ191HeadRelation? {
        nil
    }

    /// Item 6; `open-one-pull-request-per-repository.md#unpublished-commits-pin`: pins the held Worktree's HEAD
    /// under a local ref outside `refs/heads/` when it is not `recordedCommit`, descendant or not. Never pushes.
    /// The ref name is an engine detail.
    static func pinUnpublishedHead(
        worktreePath: String, recordedCommit: String, branch: FeatureBranch
    ) async -> OQ191PinResult? {
        nil
    }
}
