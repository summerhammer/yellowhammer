import Domain
import Foundation
import Repositories
import Testing

@Suite("Merge tester tests")
struct MergeTests {

    // MARK: - Single Repository Tests

    @Test("Single repo: Mainline has not moved, branch merges cleanly on top")
    func mainlineNotMoved() async throws {
        let fixture = GitFixture(name: "merge-not-moved-1")
        await fixture.initRepo(defaultBranch: "main")

        let mainSHA = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == mainSHA)
        #expect(result.mainlineRef == "refs/heads/main")
        #expect(result.isMainlineConflict == false)
    }

    @Test("Single repo: Mainline moved compatibly is clean, but clean says nothing about the build")
    func mainlineMovedCompatibly() async throws {
        let fixture = GitFixture(name: "merge-moved-compat-2")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])
        let mainSHA = try await fixture.commit(
            filename: "other.txt", content: "other", message: "unrelated main commit"
        )

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == mainSHA)
    }

    @Test("Single repo: Mainline and branch edit the same file differently is a Mainline Conflict")
    func sameFileEditedDifferently() async throws {
        let fixture = GitFixture(name: "merge-conflict-3")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .conflicting(paths: ["f.txt"]))
        #expect(result.isMainlineConflict == true)
        #expect(result.conflictingPaths == ["f.txt"])
    }

    @Test("Single repo: Multiple conflicting files report exactly the conflicting paths, sorted")
    func multipleConflictingFiles() async throws {
        let fixture = GitFixture(name: "merge-multi-conflict-4")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "b.txt", content: "base-b", message: "initial b")
        _ = try await fixture.commit(filename: "a.txt", content: "base-a", message: "initial a")
        _ = try await fixture.commit(filename: "quiet.txt", content: "base-quiet", message: "initial quiet")

        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "a.txt", content: "feature-a", message: "feature edits a")
        _ = try await fixture.commit(filename: "b.txt", content: "feature-b", message: "feature edits b")
        _ = try await fixture.commit(filename: "quiet.txt", content: "feature-quiet", message: "feature edits quiet")

        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "a.txt", content: "main-a", message: "main edits a")
        _ = try await fixture.commit(filename: "b.txt", content: "main-b", message: "main edits b")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .conflicting(paths: ["a.txt", "b.txt"]))
        #expect(result.conflictingPaths == ["a.txt", "b.txt"])
    }

    @Test("Single repo: Branch already an ancestor of mainline is clean")
    func branchAlreadyMerged() async throws {
        let fixture = GitFixture(name: "merge-already-merged-5")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge feature", "yh-project-feature"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
    }

    @Test("Single repo: Non-existent branch is untestable")
    func nonExistentBranch() async throws {
        let fixture = GitFixture(name: "merge-nonexistent-branch-6")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(message: "initial commit")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-missing-branch", in: repo)

        guard case .untestable = result.verdict else {
            Issue.record("expected .untestable, got \(result.verdict)")
            return
        }
        #expect(result.isMainlineConflict == false)
    }

    @Test("Single repo: Non-existent repository path is untestable")
    func nonExistentPath() async throws {
        let repo = Repo(name: "ghost", path: "/tmp/nonexistent-yellowhammer-repo-\(UUID().uuidString)", role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-feat", in: repo)

        guard case .untestable = result.verdict else {
            Issue.record("expected .untestable, got \(result.verdict)")
            return
        }
    }

    @Test("Single repo: Explicit ResolvedMainline pinned to an older commit is honoured")
    func explicitResolvedMainline() async throws {
        let fixture = GitFixture(name: "merge-explicit-mainline-7")
        await fixture.initRepo(defaultBranch: "main")

        let oldMainSHA = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-test-branch"])
        let branchSHA = try await fixture.commit(
            filename: "f.txt", content: "branch-version", message: "branch edits f.txt"
        )

        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let resolvedMainline = ResolvedMainline(
            repository: "app",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: oldMainSHA
        )

        let tester = MergeTester()
        let result = await tester.testMerge(
            branch: "yh-test-branch",
            in: repo,
            mainline: resolvedMainline
        )

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == branchSHA)
        #expect(result.mainlineCommit == oldMainSHA)
        #expect(result.mainlineRef == "refs/heads/main")

        // Against current HEAD of main (which also touched f.txt), the same branch conflicts.
        let headResult = await tester.testMerge(branch: "yh-test-branch", in: repo)
        #expect(headResult.verdict == .conflicting(paths: ["f.txt"]))
    }

    @Test("Invariant: a conflicting merge test leaves the working tree, index, and refs untouched")
    func mergeTestDoesNotMutateRepository() async throws {
        let fixture = GitFixture(name: "merge-invariant-8")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let statusBefore = await fixture.run(["status", "--porcelain"]).stdout
        let refsBefore = await fixture.run(["for-each-ref"]).stdout
        let headBefore = await fixture.revParse("HEAD")
        let contentsBefore = try String(contentsOf: fixture.url.appending(component: "f.txt"), encoding: .utf8)

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)
        #expect(result.isMainlineConflict == true)

        let statusAfter = await fixture.run(["status", "--porcelain"]).stdout
        let refsAfter = await fixture.run(["for-each-ref"]).stdout
        let headAfter = await fixture.revParse("HEAD")
        let contentsAfter = try String(contentsOf: fixture.url.appending(component: "f.txt"), encoding: .utf8)

        #expect(statusBefore == statusAfter)
        #expect(refsBefore == refsAfter)
        #expect(headBefore == headAfter)
        #expect(contentsBefore == contentsAfter)
    }

    // MARK: - Multi-Repository Feature Tests

    @Test("Multi-repo: One clean and one conflicting repository is a Mainline Conflict")
    func multiRepoOneCleanOneConflicting() async throws {
        let clean = GitFixture(name: "merge-multi-clean-9")
        await clean.initRepo(defaultBranch: "main")
        _ = try await clean.commit(filename: "init.txt", content: "initial", message: "init clean")
        _ = await clean.run(["checkout", "-b", "yh-proj-feature"])
        _ = try await clean.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await clean.run(["checkout", "main"])

        let conflicting = GitFixture(name: "merge-multi-conflicting-9")
        await conflicting.initRepo(defaultBranch: "main")
        _ = try await conflicting.commit(filename: "f.txt", content: "base", message: "init conflicting")
        _ = await conflicting.run(["checkout", "-b", "yh-proj-feature"])
        _ = try await conflicting.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await conflicting.run(["checkout", "main"])
        _ = try await conflicting.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repos = [
            Repo(name: "clean-repo", path: clean.path, role: .backend),
            Repo(name: "conflicting-repo", path: conflicting.path, role: .backend)
        ]

        let branch = FeatureBranch(name: "yh-proj-feature")
        let tester = MergeTester()
        let report = await tester.evaluateMerge(
            branches: Dictionary(uniqueKeysWithValues: repos.map { ($0.name, branch) }), repos: repos
        )

        #expect(report.hasMainlineConflict == true)
        #expect(report.conflictingRepositories == ["conflicting-repo"])
        #expect(report["clean-repo"]?.verdict == .clean)
        #expect(report["conflicting-repo"]?.isMainlineConflict == true)
        #expect(report[repos[1]]?.isMainlineConflict == true)
    }

    @Test("Multi-repo: Zero repositories touched has no Mainline Conflict")
    func multiRepoZeroRepos() async throws {
        let tester = MergeTester()
        let report = await tester.evaluateMerge(branches: [:], repos: [])

        #expect(report.hasMainlineConflict == false)
        #expect(report.conflictingRepositories.isEmpty)
        #expect(report.results.isEmpty)
    }
}

// feature-authoring/select-the-next-feature #merge-test, #net-zero-branch, #tested-tip: where ancestry fails,
// mainline still shows a Squash and merge or Rebase and merge when the tip has a net change, the merge is
// clean, and the merge produces exactly mainline's tree.
@Suite("Content merge test")
struct ContentMergeTests {
    /// A repository whose `yh-feature` branch edits `shared.txt` and adds `feat.txt`; `main` is left at the base.
    private func populateFeature(_ fixture: borrowing GitFixture) async throws -> String {
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
        let tip = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nfeature line three\n", message: "edit shared"
        )
        _ = await fixture.run(["checkout", "main"])
        return tip
    }

    private func test(_ fixture: borrowing GitFixture, tip: String? = nil, branch: String = "yh-feature") async
        -> RepoMergeResult {
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        return await MergeTester().testContent(branch: branch, recordedCommit: tip, in: repo)
    }

    @Test("A squash merge is not an ancestor but is content-merged")
    func squashMergeIsContentMerged() async throws {
        let fixture = GitFixture(name: "content-squash-\(UUID().uuidString)")
        let tip = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])

        let squash = await fixture.revParse("main")

        let result = await test(fixture)

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == tip)
        #expect(result.tipHasNetChange == true)
        #expect(result.mergedTree != nil)
        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
    }

    @Test("A rebase merge after mainline moved on is content-merged")
    func rebaseMergeIsContentMerged() async throws {
        let fixture = GitFixture(name: "content-rebase-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        _ = try await fixture.commit(filename: "other.txt", content: "other\n", message: "unrelated mainline commit")
        _ = await fixture.run(["cherry-pick", "yh-feature~1", "yh-feature"])

        let result = await test(fixture)

        #expect(result.isContentMerged)
    }

    @Test("A squash merge after mainline edited unrelated lines of the same file still passes")
    func squashAfterUnrelatedMainlineEditPasses() async throws {
        let fixture = GitFixture(name: "content-unrelated-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])
        _ = try await fixture.commit(
            filename: "shared.txt", content: "edited base\nline two\nfeature line three\n", message: "edit line one"
        )

        let result = await test(fixture)

        #expect(result.verdict == .clean)
        #expect(result.isContentMerged)
    }

    @Test("A branch that is not merged at all is clean but not content-merged")
    func unmergedBranchIsNotContentMerged() async throws {
        let fixture = GitFixture(name: "content-unmerged-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)

        let result = await test(fixture)

        #expect(result.verdict == .clean)
        #expect(result.tipHasNetChange == true)
        #expect(result.landingCommit == nil)
        #expect(!result.isContentMerged)
    }

    @Test("A net-zero branch (a commit and its revert) has not merged, though the merge is clean and adds nothing")
    func netZeroBranchIsNotContentMerged() async throws {
        let fixture = GitFixture(name: "content-net-zero-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
        _ = await fixture.run(["revert", "--no-edit", "HEAD"])
        _ = await fixture.run(["checkout", "main"])

        let result = await test(fixture)

        #expect(result.verdict == .clean)
        #expect(result.tipHasNetChange == false)
        #expect(result.landingCommit == nil)
        #expect(!result.isContentMerged)
    }

    // OQ190 item 24: the content test searches mainline's history, so a later edit no longer lapses it. Until
    // 2026-10-28 these two read mainline's head only, and were not content-merged.
    @Test("A later mainline edit to the same lines does not hide the squash, which is the landing commit")
    func sameLinesEditedLaterIsStillContentMerged() async throws {
        let fixture = GitFixture(name: "content-lapsed-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])
        let squash = await fixture.revParse("main")
        _ = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nlater line three\n", message: "overwrite line three"
        )

        let result = await test(fixture)

        // The verdict is still the merge into mainline's head, which conflicts.
        #expect(result.isMainlineConflict)
        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
    }

    @Test("A later mainline deletion of the added file does not hide the squash")
    func deletedLaterIsStillContentMerged() async throws {
        let fixture = GitFixture(name: "content-deleted-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])
        let squash = await fixture.revParse("main")
        _ = await fixture.run(["rm", "feat.txt"])
        _ = await fixture.run(["commit", "-m", "drop feat"])

        let result = await test(fixture)

        #expect(result.verdict == .clean)
        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
    }

    @Test("A squash of a branch whose lines the Operator changed first is never content-merged, and conflicts")
    func squashOfChangedLinesIsNotContentMerged() async throws {
        let fixture = GitFixture(name: "content-changed-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        // The pull request's last commit, pushed by the Operator after the Pushed Tip, rewrote line three.
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        try fixture.writeFile(filename: "shared.txt", content: "base\nline two\noperator line three\n")
        _ = await fixture.run(["add", "shared.txt"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature, edited"])

        let result = await test(fixture)

        #expect(result.tipHasNetChange == true)
        #expect(result.landingCommit == nil)
        #expect(!result.isContentMerged)
        #expect(result.conflictingPaths == ["shared.txt"])
    }

    @Test("A rebase merge whose added commits come after the branch's own lands at the branch's last commit")
    func rebaseWithLaterAddedCommitsIsContentMerged() async throws {
        let fixture = GitFixture(name: "content-rebase-added-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        _ = try await fixture.commit(filename: "other.txt", content: "other\n", message: "unrelated mainline commit")
        _ = await fixture.run(["cherry-pick", "yh-feature~1", "yh-feature"])
        let rebasedTip = await fixture.revParse("main")
        // A commit the Operator added to the pull request after the Pushed Tip, rebased in after the branch's own.
        _ = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nreviewed line three\n", message: "review fix"
        )

        let result = await test(fixture)

        #expect(result.isMainlineConflict)
        #expect(result.landingCommit == rebasedTip)
        #expect(result.isContentMerged)
    }

    @Test("A commit before the fork point is never the landing commit, though it holds the same content")
    func searchStartsAfterTheForkPoint() async throws {
        let fixture = GitFixture(name: "content-fork-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "one\n", message: "init")
        _ = try await fixture.commit(filename: "shared.txt", content: "two\n", message: "two")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        // The branch puts back what mainline had before the fork point.
        _ = try await fixture.commit(filename: "shared.txt", content: "one\n", message: "back to one")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "other.txt", content: "other\n", message: "unrelated")

        let result = await test(fixture)

        #expect(result.tipHasNetChange == true)
        #expect(result.landingCommit == nil)
        #expect(!result.isContentMerged)
    }

    @Test("The recorded commit is tested, not the branch, when the branch has later commits")
    func recordedCommitWinsOverALaterBranchTip() async throws {
        let fixture = GitFixture(name: "content-recorded-\(UUID().uuidString)")
        let tip = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])
        _ = await fixture.run(["checkout", "yh-feature"])
        _ = try await fixture.commit(filename: "later.txt", content: "later\n", message: "commit after the push")
        _ = await fixture.run(["checkout", "main"])

        let byBranch = await test(fixture)
        let byCommit = await test(fixture, tip: tip)

        #expect(!byBranch.isContentMerged)
        #expect(byCommit.branchCommit == tip)
        #expect(byCommit.isContentMerged)
    }

    @Test("A recorded commit is tested although its branch ref is gone")
    func recordedCommitWithoutBranchRef() async throws {
        let fixture = GitFixture(name: "content-no-ref-\(UUID().uuidString)")
        let tip = try await populateFeature(fixture)
        _ = await fixture.run(["merge", "--squash", "yh-feature"])
        _ = await fixture.run(["commit", "-m", "squash of yh-feature"])
        _ = await fixture.run(["update-ref", "refs/yellowhammer/landed/yh-feature", tip])
        _ = await fixture.run(["branch", "-D", "yh-feature"])

        let result = await test(fixture, tip: tip)

        #expect(result.branchCommit == tip)
        #expect(result.isContentMerged)
    }

    @Test("Only with no recorded commit is the branch name read; a recorded commit the repository lacks is untestable")
    func readsTheBranchNameOnlyWithoutARecordedCommit() async throws {
        let fixture = GitFixture(name: "content-fallback-\(UUID().uuidString)")
        let tip = try await populateFeature(fixture)
        let missing = String(repeating: "ab", count: 20)

        let noRecord = await test(fixture)
        let goneRecord = await test(fixture, tip: missing)
        let neither = await test(fixture, tip: missing, branch: "no-such-branch")

        #expect(noRecord.branchCommit == tip)
        // A live branch does not stand in for a lost recorded commit (#tested-tip), and the reason says so.
        #expect(goneRecord.branchCommit == nil)
        #expect(goneRecord.verdict == .untestable(reason: "recorded commit \(missing) is not in the repository"))
        #expect(neither.branchCommit == nil)
        #expect(neither.verdict != .clean)
    }

    @Test("Tips: a repository absent from the map is untestable, and each tip is read in its own repository")
    func evaluateMergeByTips() async throws {
        let merged = GitFixture(name: "content-tips-a-\(UUID().uuidString)")
        let mergedTip = try await populateFeature(merged)
        _ = await merged.run(["merge", "--squash", "yh-feature"])
        _ = await merged.run(["commit", "-m", "squash of yh-feature"])
        let open = GitFixture(name: "content-tips-b-\(UUID().uuidString)")
        _ = try await populateFeature(open)
        let repos = [
            Repo(name: "merged", path: merged.path, role: .backend),
            Repo(name: "open", path: open.path, role: .backend),
            Repo(name: "absent", path: open.path, role: .backend)
        ]

        let report = await MergeTester().evaluateContent(
            tips: [
                "merged": TestedTip(branch: nil, recordedCommit: mergedTip),
                "open": TestedTip(branch: FeatureBranch(name: "yh-feature"))
            ],
            repos: repos
        )

        #expect(report["merged"]?.isContentMerged == true)
        #expect(report["open"]?.isContentMerged == false)
        #expect(report["open"]?.verdict == .clean)
        if case .untestable = report["absent"]?.verdict {} else { Issue.record("expected untestable") }
    }
}
