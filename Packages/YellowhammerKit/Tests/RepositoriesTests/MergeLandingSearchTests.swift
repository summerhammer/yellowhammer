import Domain
import Foundation
import Repositories
import Testing

// feature-authoring/select-the-next-feature #merge-test, #stacked-content-test: the content test's search merges the
// tip only into the mainline commits that touch the tip's paths, and finds the same landing commit as a search of
// every first-parent commit. Each fixture is checked against `ExhaustiveLandingSearch`, which runs that search by
// hand, and counts the `git merge-tree` runs through a logging `git`.

/// A `git` that logs each invocation's arguments, one line each, then runs the real git. With `failing`, an
/// invocation whose arguments contain that text exits 128 instead.
struct CountingGit: ~Copyable {
    let directory: URL
    let runner: GitRunner

    init(failing: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "counting-git-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(component: "argv").path(percentEncoded: false)
        let failure = failing.map { "case \"$*\" in *'\($0)'*) exit 128 ;; esac\n" } ?? ""
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log)'
            \(failure)exec '\(GitRunner.findGitExecutable())' "$@"

            """
        let git = directory.appending(component: "git")
        try Data(script.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        runner = GitRunner(executablePath: git.path(percentEncoded: false))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var invocations: [String] {
        let log = directory.appending(component: "argv")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    var mergeTreeRuns: Int {
        invocations.filter { $0.contains(" merge-tree ") }.count
    }
}

/// The landing search before path limiting, run by hand: every commit given, oldest first, until one absorbs the tip.
enum ExhaustiveLandingSearch {
    static func landing(
        in path: String, tip: String, candidates: [String], mergeBase: String? = nil
    ) async -> String? {
        let git = GitRunner()
        for candidate in candidates {
            let merge = await git.run(
                ["-C", path, "merge-tree", "--write-tree"] + (mergeBase.map { ["--merge-base=\($0)"] } ?? [])
                    + [candidate, tip]
            )
            let tree = await git.run(["-C", path, "rev-parse", "\(candidate)^{tree}"])
            let merged = merge.stdout.split(separator: "\n").first.map(String.init)
            if merge.isSuccess, merged == tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
                return candidate
            }
        }
        return nil
    }

    /// Mainline's first-parent chain after `start`, oldest first.
    static func chain(in path: String, after start: String, upTo mainline: String = "main") async -> [String] {
        let result = await GitRunner().run(
            ["-C", path, "rev-list", "--first-parent", "--reverse", "\(start)..\(mainline)"]
        )
        return result.stdout.split(separator: "\n").map(String.init)
    }
}

extension GitFixture {
    /// `count` mainline commits, each adding its own file, none touching a Feature's paths.
    func unrelatedCommits(_ count: Int, tag: String) async throws {
        for index in 0..<count {
            _ = try await commit(
                filename: "unrelated-\(tag)-\(index).txt", content: "\(tag) \(index)\n", message: "\(tag) \(index)"
            )
        }
    }

    func squash(_ branch: String, message: String? = nil) async -> String? {
        _ = await run(["merge", "--squash", branch])
        _ = await run(["commit", "-m", message ?? "squash of \(branch)"])
        return await revParse("HEAD")
    }
}

@Suite("Content test: path-limited landing search")
struct LandingSearchTests {
    /// `yh-feature` edits line three of `shared.txt` and adds `feat.txt`; `main` is left at the base.
    private func populateFeature(_ fixture: borrowing GitFixture) async throws -> (fork: String, tip: String) {
        await fixture.initRepo(defaultBranch: "main")
        let fork = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nline three\n", message: "init"
        )
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
        let tip = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nfeature line three\n", message: "edit shared"
        )
        _ = await fixture.run(["checkout", "main"])
        return (fork, tip)
    }

    private func test(
        _ fixture: borrowing GitFixture, git: borrowing CountingGit, branch: String = "yh-feature"
    ) async -> RepoMergeResult {
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        return await MergeTester(git: git.runner).testContent(branch: branch, recordedCommit: nil, in: repo)
    }

    private func exhaustiveLanding(_ fixture: borrowing GitFixture, fork: String, tip: String) async -> String? {
        let chain = await ExhaustiveLandingSearch.chain(in: fixture.path, after: fork)
        return await ExhaustiveLandingSearch.landing(in: fixture.path, tip: tip, candidates: chain)
    }

    @Test("An unmerged branch is merged only into mainline's head, never into the unrelated commits before it")
    func unmergedSkipsUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "landing-unmerged-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(6, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.verdict == .clean)
        #expect(result.tipHasNetChange == true)
        #expect(result.landingCommit == nil)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == nil)
        // Before path limiting: 6, one per first-parent commit, the head's reused as the verdict.
        #expect(git.mergeTreeRuns == 1)
    }

    @Test("A squash among unrelated commits is the landing commit, and only it and the head are merged into")
    func squashAmongUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "landing-squash-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(3, tag: "before")
        let squash = await fixture.squash("yh-feature")
        try await fixture.unrelatedCommits(3, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == squash)
        // Before path limiting: 5, the three commits before the squash, the squash, and the head.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("A rebase merge among unrelated commits lands at the branch's last commit")
    func rebaseAmongUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "landing-rebase-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(2, tag: "before")
        _ = await fixture.run(["cherry-pick", "yh-feature~1"])
        try await fixture.unrelatedCommits(2, tag: "between")
        _ = await fixture.run(["cherry-pick", "yh-feature"])
        let rebasedTip = await fixture.revParse("main")
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.landingCommit == rebasedTip)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == rebasedTip)
        // Before path limiting: 7. Now the two rebased commits and the head.
        #expect(git.mergeTreeRuns == 3)
    }

    @Test("A later edit to the same lines among unrelated commits keeps the squash, and the head conflicts")
    func laterSameLinesEditAmongUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "landing-lapsed-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(2, tag: "before")
        let squash = await fixture.squash("yh-feature")
        try await fixture.unrelatedCommits(2, tag: "between")
        _ = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nlater line three\n", message: "overwrite line three"
        )
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.isMainlineConflict)
        #expect(result.conflictingPaths == ["shared.txt"])
        #expect(result.landingCommit == squash)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == squash)
        // Before path limiting: 4, the commits up to the squash, and the head.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("A conflict at the head of an unmerged branch is still a Mainline Conflict")
    func conflictAtTheHeadIsAMainlineConflict() async throws {
        let fixture = GitFixture(name: "landing-conflict-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(2, tag: "before")
        _ = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nmainline line three\n", message: "mainline edits it"
        )
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.isMainlineConflict)
        #expect(result.conflictingPaths == ["shared.txt"])
        #expect(result.landingCommit == nil)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == nil)
        // Before path limiting: 5. Now the conflicting edit and the head.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("A landing that enters mainline through a --no-ff merge of another branch is that merge commit")
    func landingThroughANoFastForwardMerge() async throws {
        let fixture = GitFixture(name: "landing-no-ff-\(UUID().uuidString)")
        let (fork, tip) = try await populateFeature(fixture)
        _ = await fixture.run(["checkout", "-b", "integration"])
        _ = await fixture.squash("yh-feature")
        _ = try await fixture.commit(filename: "integration.txt", content: "integration\n", message: "integration")
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(2, tag: "before")
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge integration", "integration"])
        let merge = await fixture.revParse("main")
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.landingCommit == merge)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == merge)
        // Before path limiting: 4. The merge matches its second parent on the tip's paths, and is still kept.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("File names with glob characters, a leading colon or spaces are matched as they are")
    func specialCharacterPaths() async throws {
        let fixture = GitFixture(name: "landing-special-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        let fork = try await fixture.commit(filename: "base.txt", content: "base\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        for name in ["*.txt", ":colon.txt", "dir [1]/a?.txt", "space name.txt", "quote\"d.txt"] {
            _ = try await fixture.commit(filename: name, content: "feature \(name)\n", message: "add \(name)")
        }
        let tip = try #require(await fixture.revParse("yh-feature"))
        _ = await fixture.run(["checkout", "main"])
        // Paths that a pathspec `*.txt` or `dir [1]/a?.txt` would also match.
        _ = try await fixture.commit(filename: "x.txt", content: "x\n", message: "glob decoy")
        _ = try await fixture.commit(filename: "dir [1]/ab.txt", content: "ab\n", message: "glob decoy in dir")
        let squash = await fixture.squash("yh-feature")
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(result.landingCommit == squash)
        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == squash)
        // Before path limiting: 4.
        #expect(git.mergeTreeRuns == 2)
    }

    // `git merge-tree` detects renames, so a change can land at a path the tip never named. These keep the search
    // of every first-parent commit, and find what it finds.
    @Test("A squash that lands in a directory mainline renamed is still found")
    func mainlineDirectoryRename() async throws {
        let fixture = GitFixture(name: "landing-dir-rename-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        // By default the relocated file is a conflict, and nothing absorbs the tip.
        _ = await fixture.run(["config", "merge.directoryRenames", "true"])
        let lines = (1...40).map(String.init).joined(separator: "\n") + "\n"
        let fork = try await fixture.commit(filename: "d/a.txt", content: lines, message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(filename: "d/new.txt", content: "new\n", message: "add d/new")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["mv", "d", "e"])
        _ = await fixture.run(["commit", "-m", "rename d to e"])
        let squash = try await fixture.commit(filename: "e/new.txt", content: "new\n", message: "squash lands e/new")
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == squash)
        #expect(result.landingCommit == squash)
    }

    @Test("A squash that lands on a file mainline renamed is still found")
    func mainlineFileRename() async throws {
        let fixture = GitFixture(name: "landing-file-rename-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        let lines = (1...40).map(String.init)
        let fork = try await fixture.commit(
            filename: "shared.txt", content: lines.joined(separator: "\n") + "\n", message: "init"
        )
        var edited = lines
        edited[19] = "feature 20"
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
        let tip = try await fixture.commit(
            filename: "shared.txt", content: edited.joined(separator: "\n") + "\n", message: "edit shared"
        )
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(1, tag: "before")
        _ = try await fixture.commit(filename: "feat.txt", content: "feature\n", message: "squash part one")
        _ = await fixture.run(["mv", "shared.txt", "moved.txt"])
        _ = await fixture.run(["commit", "-m", "rename shared to moved"])
        // Touches only moved.txt, a path the tip never named.
        let landing = try await fixture.commit(
            filename: "moved.txt", content: edited.joined(separator: "\n") + "\n", message: "squash part two"
        )
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == landing)
        #expect(result.landingCommit == landing)
    }

    @Test("A tip that renames a directory mainline added to lands where mainline takes the addition back out")
    func tipDirectoryRenameWithMainlineAdd() async throws {
        let fixture = GitFixture(name: "landing-tip-rename-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        let lines = (1...40).map(String.init).joined(separator: "\n") + "\n"
        let fork = try await fixture.commit(filename: "d/a.txt", content: lines, message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = await fixture.run(["mv", "d", "e"])
        _ = await fixture.run(["commit", "-m", "rename d to e"])
        let tip = try #require(await fixture.revParse("HEAD"))
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "d/x.txt", content: "x\n", message: "mainline adds d/x")
        try FileManager.default.createDirectory(
            at: fixture.url.appending(component: "e"), withIntermediateDirectories: true
        )
        _ = await fixture.run(["mv", "d/a.txt", "e/a.txt"])
        _ = await fixture.run(["commit", "-m", "squash moves d/a to e/a"])
        // The merge moves d/x into the tip's renamed directory until mainline drops it: this commit touches only
        // d/x, a path the tip never named.
        _ = await fixture.run(["rm", "d/x.txt"])
        _ = await fixture.run(["commit", "-m", "drop d/x"])
        let landing = await fixture.revParse("HEAD")
        try await fixture.unrelatedCommits(1, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == landing)
        #expect(result.landingCommit == landing)
    }

    @Test("A fork point reached through a merge's second parent finds what the full search finds")
    func forkPointOffTheFirstParentChain() async throws {
        let fixture = GitFixture(name: "landing-side-fork-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "side"])
        let fork = try await fixture.commit(filename: "side.txt", content: "side\n", message: "side")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nfeature line three\n", message: "edit shared"
        )
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(2, tag: "before")
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge side", "side"])
        let squash = await fixture.squash("yh-feature")
        try await fixture.unrelatedCommits(1, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, git: git)

        #expect(await exhaustiveLanding(fixture, fork: fork, tip: tip) == squash)
        #expect(result.landingCommit == squash)
    }

    @Test(
        "A failed read of the changed paths searches every first-parent commit, never reporting no landing",
        arguments: ["diff --name-status", "log --first-parent"]
    )
    func failedPathReadSearchesEverything(failing: String) async throws {
        let fixture = GitFixture(name: "landing-read-fails-\(UUID().uuidString)")
        _ = try await populateFeature(fixture)
        try await fixture.unrelatedCommits(3, tag: "before")
        let squash = await fixture.squash("yh-feature")
        try await fixture.unrelatedCommits(1, tag: "after")
        let git = try CountingGit(failing: failing)

        let result = await test(fixture, git: git)

        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
        // The three commits before the squash, the squash, and the head: the search of every commit.
        #expect(git.mergeTreeRuns == 5)
    }
}

@Suite("Stacked content test: path-limited landing search")
struct StackedLandingSearchTests {
    private struct Stack {
        let recordedBase: String
        let lowerLanding: String
        let tip: String
    }

    /// `yh-lower` adds `lower.txt`; `yh-upper`, based on it, edits `shared.txt` and adds `upper.txt`. `yh-lower` is
    /// squash-merged into `main`; `yh-upper` is not.
    private func populateStack(_ fixture: borrowing GitFixture) async throws -> Stack {
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-lower"])
        let recordedBase = try await fixture.commit(filename: "lower.txt", content: "lower\n", message: "lower")
        _ = await fixture.run(["checkout", "-b", "yh-upper"])
        _ = try await fixture.commit(filename: "upper.txt", content: "upper\n", message: "add upper")
        let tip = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nupper line three\n", message: "edit shared"
        )
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(1, tag: "below")
        let lowerLanding = try #require(await fixture.squash("yh-lower"))
        return Stack(recordedBase: recordedBase, lowerLanding: lowerLanding, tip: tip)
    }

    private func test(
        _ fixture: borrowing GitFixture, stack: Stack, git: borrowing CountingGit
    ) async -> RepoMergeResult {
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        return await MergeTester(git: git.runner).testStackedContent(
            branch: "yh-upper", recordedCommit: nil, in: repo,
            anchor: StackedContentAnchor(recordedBase: stack.recordedBase, lowerLandingCommit: stack.lowerLanding)
        )
    }

    private func exhaustiveLanding(_ fixture: borrowing GitFixture, stack: Stack) async -> String? {
        let chain = await ExhaustiveLandingSearch.chain(in: fixture.path, after: stack.lowerLanding)
        return await ExhaustiveLandingSearch.landing(
            in: fixture.path, tip: stack.tip, candidates: [stack.lowerLanding] + chain, mergeBase: stack.recordedBase
        )
    }

    @Test("An unmerged stacked branch is merged only into the lower landing commit and the head")
    func unmergedSkipsUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "stacked-unmerged-\(UUID().uuidString)")
        let stack = try await populateStack(fixture)
        try await fixture.unrelatedCommits(5, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.verdict == .clean)
        #expect(result.landingCommit == nil)
        #expect(await exhaustiveLanding(fixture, stack: stack) == nil)
        // Before path limiting: 7, the lower landing commit, five unrelated commits, and the head.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("A stacked squash among unrelated commits is the landing commit")
    func squashAmongUnrelatedCommits() async throws {
        let fixture = GitFixture(name: "stacked-squash-\(UUID().uuidString)")
        let stack = try await populateStack(fixture)
        try await fixture.unrelatedCommits(3, tag: "before")
        let squash = await fixture.squash("yh-upper")
        try await fixture.unrelatedCommits(2, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.landingCommit == squash)
        #expect(result.isContentMerged)
        #expect(await exhaustiveLanding(fixture, stack: stack) == squash)
        // Before path limiting: 6, the lower landing commit, three unrelated commits, the squash, and the head.
        #expect(git.mergeTreeRuns == 3)
    }

    @Test("With mainline unmoved below the lower landing commit, the stacked search still skips unrelated commits")
    func lowerLandingWithTheRecordedBaseTree() async throws {
        let fixture = GitFixture(name: "stacked-unmoved-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-lower"])
        let recordedBase = try await fixture.commit(filename: "lower.txt", content: "lower\n", message: "lower")
        _ = await fixture.run(["checkout", "-b", "yh-upper"])
        let tip = try await fixture.commit(filename: "upper.txt", content: "upper\n", message: "add upper")
        _ = await fixture.run(["checkout", "main"])
        // The squash's tree is the recorded base's: the two have no changes between them.
        let lowerLanding = try #require(await fixture.squash("yh-lower"))
        try await fixture.unrelatedCommits(3, tag: "before")
        let squash = await fixture.squash("yh-upper")
        try await fixture.unrelatedCommits(2, tag: "after")
        let stack = Stack(recordedBase: recordedBase, lowerLanding: lowerLanding, tip: tip)
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.landingCommit == squash)
        #expect(await exhaustiveLanding(fixture, stack: stack) == squash)
        // Before path limiting: 6, the lower landing commit, three unrelated commits, the squash, and the head.
        #expect(git.mergeTreeRuns == 3)
    }

    @Test("A stacked branch merged into the lower branch before its squash lands at the lower landing commit")
    func landsAtTheLowerLandingCommit() async throws {
        let fixture = GitFixture(name: "stacked-same-commit-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-lower"])
        let recordedBase = try await fixture.commit(filename: "lower.txt", content: "lower\n", message: "lower")
        _ = await fixture.run(["checkout", "-b", "yh-upper"])
        let tip = try await fixture.commit(filename: "upper.txt", content: "upper\n", message: "add upper")
        _ = await fixture.run(["checkout", "yh-lower"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge upper into lower", "yh-upper"])
        _ = await fixture.run(["checkout", "main"])
        let lowerLanding = try #require(await fixture.squash("yh-lower"))
        try await fixture.unrelatedCommits(3, tag: "after")
        let stack = Stack(recordedBase: recordedBase, lowerLanding: lowerLanding, tip: tip)
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.landingCommit == lowerLanding)
        #expect(await exhaustiveLanding(fixture, stack: stack) == lowerLanding)
        // Before path limiting: 2, the lower landing commit and the head.
        #expect(git.mergeTreeRuns == 2)
    }

    @Test("A later same-lines edit keeps the stacked squash, and a conflict at the head is a Mainline Conflict")
    func laterSameLinesEditConflictsAtTheHead() async throws {
        let fixture = GitFixture(name: "stacked-lapsed-\(UUID().uuidString)")
        let stack = try await populateStack(fixture)
        try await fixture.unrelatedCommits(2, tag: "before")
        let squash = await fixture.squash("yh-upper")
        try await fixture.unrelatedCommits(2, tag: "between")
        _ = try await fixture.commit(
            filename: "shared.txt", content: "base\nline two\nlater line three\n", message: "overwrite line three"
        )
        try await fixture.unrelatedCommits(1, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.isMainlineConflict)
        #expect(result.conflictingPaths == ["shared.txt"])
        #expect(result.landingCommit == squash)
        #expect(await exhaustiveLanding(fixture, stack: stack) == squash)
        // Before path limiting: 5, the lower landing commit, two unrelated commits, the squash, and the head.
        #expect(git.mergeTreeRuns == 3)
    }

    @Test("A stacked landing through a --no-ff merge of another branch is that merge commit")
    func landingThroughANoFastForwardMerge() async throws {
        let fixture = GitFixture(name: "stacked-no-ff-\(UUID().uuidString)")
        let stack = try await populateStack(fixture)
        _ = await fixture.run(["checkout", "-b", "integration"])
        _ = await fixture.squash("yh-upper")
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(2, tag: "before")
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge integration", "integration"])
        let merge = await fixture.revParse("main")
        try await fixture.unrelatedCommits(1, tag: "after")
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(result.landingCommit == merge)
        #expect(await exhaustiveLanding(fixture, stack: stack) == merge)
        #expect(git.mergeTreeRuns == 3)
    }

    @Test("A stacked squash that lands in a directory mainline renamed is still found")
    func mainlineDirectoryRename() async throws {
        let fixture = GitFixture(name: "stacked-dir-rename-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = await fixture.run(["config", "merge.directoryRenames", "true"])
        let lines = (1...40).map(String.init).joined(separator: "\n") + "\n"
        _ = try await fixture.commit(filename: "d/a.txt", content: lines, message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-lower"])
        let recordedBase = try await fixture.commit(filename: "lower.txt", content: "lower\n", message: "lower")
        _ = await fixture.run(["checkout", "-b", "yh-upper"])
        let tip = try await fixture.commit(filename: "d/new.txt", content: "new\n", message: "add d/new")
        _ = await fixture.run(["checkout", "main"])
        try await fixture.unrelatedCommits(1, tag: "below")
        let lowerLanding = try #require(await fixture.squash("yh-lower"))
        _ = await fixture.run(["mv", "d", "e"])
        _ = await fixture.run(["commit", "-m", "rename d to e"])
        let squash = try await fixture.commit(filename: "e/new.txt", content: "new\n", message: "squash lands e/new")
        try await fixture.unrelatedCommits(1, tag: "after")
        let stack = Stack(recordedBase: recordedBase, lowerLanding: lowerLanding, tip: tip)
        let git = try CountingGit()

        let result = await test(fixture, stack: stack, git: git)

        #expect(await exhaustiveLanding(fixture, stack: stack) == squash)
        #expect(result.landingCommit == squash)
    }
}
