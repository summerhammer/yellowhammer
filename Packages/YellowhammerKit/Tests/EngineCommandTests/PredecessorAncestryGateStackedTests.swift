import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #stacked-content-test, #net-zero-branch, #stacked-merge-order and
// #merge-test (OQ190 item 25): a Feature whose recorded base in a repository is the Pushed Tip of a Feature below
// it is tested by content only once that Feature has its Observed Merge there, searching mainline's first-parent
// chain from that Feature's landing commit with the recorded base as the base of each three-way merge and of the
// net-change check. Real git, local only.

private let lowerBranch = "yh-f1"
private let upperBranch = "yh-f2"

private func revParse(_ ref: String, in repo: borrowing GateGitFixture) async -> String {
    await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func repositories(_ repo: borrowing GateGitFixture) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)])
}

private func squashMerge(_ branch: String, in repo: borrowing GateGitFixture) async -> String {
    _ = await repo.run(["merge", "--squash", branch])
    _ = await repo.run(["commit", "-m", "squash of \(branch)"])
    return await revParse("main", in: repo)
}

/// `f.txt` on `main`, and Feature 1's branch `yh-f1` adding a line to it; `main` is left checked out at the base.
/// Returns Feature 1's tip.
private func populateLowerFeature(_ repo: borrowing GateGitFixture) async throws -> String {
    await repo.initRepo()
    _ = try await repo.commit(filename: "f.txt", content: "a\nb\nc\n", message: "init")
    _ = await repo.run(["checkout", "-b", lowerBranch])
    let tip = try await repo.commit(filename: "f.txt", content: "a\nb\nc\nX\n", message: "feature 1")
    _ = await repo.run(["checkout", "main"])
    return tip
}

/// Feature 2's branch `yh-f2`, cut from Feature 1's tip: one commit writing `files`. Returns its tip; `main` is
/// left checked out.
private func commitUpperFeature(
    _ repo: borrowing GateGitFixture, files: [(name: String, content: String)]
) async throws -> String {
    _ = await repo.run(["checkout", "-b", upperBranch, lowerBranch])
    var tip = ""
    for file in files {
        tip = try await repo.commit(filename: file.name, content: file.content, message: "feature 2: \(file.name)")
    }
    _ = await repo.run(["checkout", "main"])
    return tip
}

/// Feature 1 and Feature 2 in U, both landed with their Pushed Tips recorded, Feature 2's backend base recorded as
/// Feature 1's Pushed Tip (stacked on it), as the author Act records it at selection.
private func insertStack(
    _ journal: JournalStore, lowerTip: String, upperTip: String
) throws -> (lower: Int64, upper: Int64) {
    let lower = try insertGateFeature(
        journal, issueID: "F1", branch: lowerBranch, repositories: ["backend"], landed: true,
        pushedTips: ["backend": lowerTip]
    )
    let upper = try insertGateFeature(
        journal, issueID: "F2", branch: upperBranch, repositories: ["backend"], landed: true,
        pushedTips: ["backend": upperTip]
    )
    try journal.recordFeatureBases(featureID: upper, bases: [FeatureBaseRecord(
        repository: "backend", baseRef: "refs/yellowhammer/landed/\(lowerBranch)", baseCommit: lowerTip,
        stackedOnFeatureID: lower
    )])
    return (lower, upper)
}

/// Case S4b: Feature 2 undoes Feature 1's whole change and adds `g.txt`, which mainline already gained on its
/// own before Feature 1 landed, so mainline's tree before Feature 1 equals Feature 2's tree.
private func populateUndoingStack(_ repo: borrowing GateGitFixture) async throws -> (lower: String, upper: String) {
    let lower = try await populateLowerFeature(repo)
    let upper = try await commitUpperFeature(repo, files: [("f.txt", "a\nb\nc\n"), ("g.txt", "g\n")])
    _ = try await repo.commit(filename: "g.txt", content: "g\n", message: "mainline gains g on its own")
    return (lower, upper)
}

@Suite("Predecessor gate: a stacked Feature is tested by content from the lower Feature's landing commit")
struct PredecessorAncestryGateStackedTests {
    @Test("S4b: with the Feature below unmerged, a stacked Feature mainline already matches stays unmerged")
    func undoingStackedFeatureStaysUnmergedWhileTheLowerIsUnmerged() async throws {
        let repo = GateGitFixture(name: "stacked-s4b-open")
        let tips = try await populateUndoingStack(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: tips.lower, upperTip: tips.upper)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landings(featureID: features.lower).isEmpty)
        #expect(try journal.landings(featureID: features.upper).isEmpty)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["F1", "F2"])
    }

    @Test("S4b: after the Feature below is squash-merged, a stacked Feature that undoes part of it stays unmerged")
    func undoingStackedFeatureStaysUnmergedAfterTheLowerSquash() async throws {
        let repo = GateGitFixture(name: "stacked-s4b-squash")
        let tips = try await populateUndoingStack(repo)
        let lowerSquash = await squashMerge(lowerBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: tips.lower, upperTip: tips.upper)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landingCommits(featureID: features.lower) == ["backend": lowerSquash])
        #expect(try journal.landings(featureID: features.upper).isEmpty)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["F2"])
    }

    @Test("Both squash-merged: one pass observes the lower Feature, then the stacked one at its own squash commit")
    func bothSquashMergedAreObservedInOnePass() async throws {
        let repo = GateGitFixture(name: "stacked-both-squash")
        let lowerTip = try await populateLowerFeature(repo)
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        let lowerSquash = await squashMerge(lowerBranch, in: repo)
        let upperSquash = await squashMerge(upperBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: upperTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        #expect(try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1) == .open)

        #expect(try journal.landingCommits(featureID: features.lower) == ["backend": lowerSquash])
        #expect(try journal.landingCommits(featureID: features.upper) == ["backend": upperSquash])
        #expect(try journal.landingEvidence(featureID: features.upper) == ["backend": .content])
        #expect(try journal.unmergedFeatureStack().isEmpty)
    }

    // #stacked-merge-order: an upper pull request merged first merges into the lower Feature's branch; when that
    // branch is then squash-merged, the lower Feature's landing commit carries both changes.
    @Test(
        "Git older than 2.40 takes no --merge-base: the stacked content test is skipped, the lower is still observed",
        arguments: [GitVersion(major: 2, minor: 38, patch: 0), GitVersion(major: 2, minor: 39, patch: 5), nil]
    )
    func olderGitSkipsTheStackedContentTest(version: GitVersion?) async throws {
        let repo = GateGitFixture(name: "stacked-old-git")
        let lowerTip = try await populateLowerFeature(repo)
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        let lowerSquash = await squashMerge(lowerBranch, in: repo)
        _ = await squashMerge(upperBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: upperTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))
        let gate = PredecessorAncestryGate(gitVersion: GitVersionReader(fixed: version))

        _ = try await gate.check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landingCommits(featureID: features.lower) == ["backend": lowerSquash])
        #expect(try journal.landings(featureID: features.upper).isEmpty)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["F2"])
    }

    @Test("Git 2.40 takes --merge-base: the stacked content test runs")
    func gitTwoFortyRunsTheStackedContentTest() async throws {
        let repo = GateGitFixture(name: "stacked-git-2-40")
        let lowerTip = try await populateLowerFeature(repo)
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        _ = await squashMerge(lowerBranch, in: repo)
        let upperSquash = await squashMerge(upperBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: upperTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))
        let gitTwoForty = GitVersionReader(fixed: GitVersion(major: 2, minor: 40, patch: 0))
        let gate = PredecessorAncestryGate(gitVersion: gitTwoForty)

        _ = try await gate.check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landingCommits(featureID: features.upper) == ["backend": upperSquash])
    }

    @Test("Upper merged into the lower branch, then the lower squash-merged: both observed at that squash commit")
    func upperMergedIntoTheLowerBranchThenSquashed() async throws {
        let repo = GateGitFixture(name: "stacked-upper-first")
        let lowerTip = try await populateLowerFeature(repo)
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        _ = await repo.run(["checkout", lowerBranch])
        _ = await repo.run(["merge", "--no-ff", "-m", "merge yh-f2 into yh-f1", upperBranch])
        _ = await repo.run(["checkout", "main"])
        let squash = await squashMerge(lowerBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: upperTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        #expect(try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1) == .open)

        #expect(try journal.landingCommits(featureID: features.lower) == ["backend": squash])
        #expect(try journal.landingCommits(featureID: features.upper) == ["backend": squash])
    }

    @Test("A stacked Feature with no change of its own over the recorded base is never observed by content")
    func stackedFeatureWithNoNetChangeOverItsBaseIsNotObserved() async throws {
        let repo = GateGitFixture(name: "stacked-net-zero")
        let lowerTip = try await populateLowerFeature(repo)
        // A commit and its revert on Feature 1's tip: Feature 2's tree is the recorded base's.
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        _ = await repo.run(["checkout", upperBranch])
        _ = await repo.run(["revert", "--no-edit", "HEAD"])
        let revertedTip = await revParse("HEAD", in: repo)
        _ = await repo.run(["checkout", "main"])
        #expect(revertedTip != upperTip)
        let lowerSquash = await squashMerge(lowerBranch, in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: revertedTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landingCommits(featureID: features.lower) == ["backend": lowerSquash])
        #expect(try journal.landings(featureID: features.upper).isEmpty)
    }

    @Test("A lower landing commit that is not on mainline anchors nothing: the stacked Feature stays unmerged")
    func landingCommitOffMainlineAnchorsNothing() async throws {
        let repo = GateGitFixture(name: "stacked-off-mainline")
        let tips = try await populateUndoingStack(repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: tips.lower, upperTip: tips.upper)
        // Recorded by an earlier pass at a commit mainline no longer has on its history (a rewritten mainline).
        try journal.recordLanding(
            featureID: features.lower, repository: "backend", landingCommit: tips.lower, mainlineCommit: tips.lower,
            evidence: .content
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landings(featureID: features.upper).isEmpty)
    }

    @Test("Ancestry is unchanged: a stacked Feature merged with a merge commit passes before the lower is observed")
    func stackedMergeCommitPassesByAncestry() async throws {
        let repo = GateGitFixture(name: "stacked-ancestry")
        let lowerTip = try await populateLowerFeature(repo)
        let upperTip = try await commitUpperFeature(repo, files: [("h.txt", "h\n")])
        _ = await repo.run(["merge", "--no-ff", "-m", "merge yh-f2", upperBranch])
        let merge = await revParse("main", in: repo)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let features = try insertStack(journal, lowerTip: lowerTip, upperTip: upperTip)
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(try journal.landingCommits(featureID: features.upper) == ["backend": merge])
        #expect(try journal.landingEvidence(featureID: features.upper) == ["backend": .ancestry])
    }
}
