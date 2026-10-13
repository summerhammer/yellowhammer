import Domain
import Foundation

/// The verdict of a local merge test: whether a Feature Branch merges cleanly into mainline.
public enum MergeVerdict: Equatable, Sendable {
    case clean
    case conflicting(paths: [String])
    case untestable(reason: String)
}

/// The result of a merge test for a single repository.
public struct RepoMergeResult: Equatable, Sendable {
    public let repository: String
    public let branch: String
    public let verdict: MergeVerdict
    public let branchCommit: String?
    /// The ref the verdict was read against, e.g. "refs/remotes/origin/main".
    public let mainlineRef: String?
    public let mainlineCommit: String?
    /// The tree OID `git merge-tree --write-tree` printed for a clean merge; nil for any other verdict.
    public let mergedTree: String?
    /// The tree of `mainlineCommit`; read only for a clean merge.
    public let mainlineTree: String?
    /// Whether the tip's tree differs from the tree of `git merge-base <mainline> <tip>` — the branch has a
    /// net change at all. Read only for a clean merge; nil when it could not be read.
    public let tipHasNetChange: Bool?

    /// Whether this result is a Mainline Conflict: a Feature Branch that will not merge cleanly.
    public var isMainlineConflict: Bool {
        if case .conflicting = verdict { return true }
        return false
    }

    /// The conflicting paths, or an empty list unless `verdict` is `.conflicting`.
    public var conflictingPaths: [String] {
        if case .conflicting(let paths) = verdict { return paths }
        return []
    }

    /// Whether mainline still shows the tip's net changes although the tip is not an ancestor of it — a
    /// Squash and merge or Rebase and merge (feature-authoring/select-the-next-feature, #merge-test). All
    /// three hold: the tip has a net change; the merge is clean; and it produces exactly mainline's tree, so
    /// merging would add nothing. A branch with no net change (a commit and its revert) is never merged,
    /// though the other two would hold for it.
    public var isContentMerged: Bool {
        guard tipHasNetChange == true, case .clean = verdict, let mergedTree else { return false }
        return mergedTree == mainlineTree
    }

    public init(
        repository: String,
        branch: String,
        verdict: MergeVerdict,
        branchCommit: String? = nil,
        mainlineRef: String? = nil,
        mainlineCommit: String? = nil,
        mergedTree: String? = nil,
        mainlineTree: String? = nil,
        tipHasNetChange: Bool? = nil
    ) {
        self.repository = repository
        self.branch = branch
        self.verdict = verdict
        self.branchCommit = branchCommit
        self.mainlineRef = mainlineRef
        self.mainlineCommit = mainlineCommit
        self.mergedTree = mergedTree
        self.mainlineTree = mainlineTree
        self.tipHasNetChange = tipHasNetChange
    }
}

/// A report of merge tests across all repositories touched by a Feature, each against the Feature
/// Branch recorded for that repository.
public struct FeatureMergeReport: Equatable, Sendable {
    /// The Feature Branch tested per repository name.
    public let branches: [String: FeatureBranch]
    public let results: [RepoMergeResult]

    /// Repositories whose merge test reported a Mainline Conflict.
    public var conflictingRepositories: [String] {
        results.filter(\.isMainlineConflict).map(\.repository)
    }

    /// Whether any touched repository reported a Mainline Conflict.
    public var hasMainlineConflict: Bool {
        results.contains { $0.isMainlineConflict }
    }

    public subscript(repositoryName: String) -> RepoMergeResult? {
        results.first { $0.repository == repositoryName }
    }

    public subscript(repo: Repo) -> RepoMergeResult? {
        results.first { $0.repository == repo.name }
    }

    public init(
        branches: [String: FeatureBranch],
        results: [RepoMergeResult]
    ) {
        self.branches = branches
        self.results = results
    }
}

/// Tests whether a Feature Branch merges cleanly into a repository's Mainline.
///
/// Pure local Git evaluation using `git merge-tree`. Reads against remote-tracking mainline
/// as refreshed at Act start (or a cached ref if offline), touches no working tree, index,
/// ref, or commit, and requires no network access. A Mainline Conflict is detected and
/// reported, never resolved; it mints no Block Reason. A clean verdict is a textual result
/// only — it is never a claim that merging is safe.
public struct MergeTester: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Evaluates the merge test across all repositories touched by the Feature, each against its own
    /// Feature Branch in `branches`. A repository absent from the map is untestable without running git.
    public func evaluateMerge(
        branches: [String: FeatureBranch],
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureMergeReport {
        var results: [RepoMergeResult] = []
        for repo in repos {
            guard let branch = branches[repo.name] else {
                results.append(
                    RepoMergeResult(
                        repository: repo.name, branch: "",
                        verdict: .untestable(reason: "no Feature Branch recorded for \(repo.name)")
                    )
                )
                continue
            }
            let mainline = mainlines?[repo.name]
            results.append(await testMerge(branch: branch.name, in: repo, mainline: mainline))
        }
        return FeatureMergeReport(branches: branches, results: results)
    }

    /// Evaluates the merge test across `repos`, each against its own ``TestedTip``: the recorded commit alone
    /// when one was recorded, else the Feature Branch (#tested-tip). A repository absent from `tips`, or whose
    /// tip resolves to no commit (including a recorded commit the repository lost), is untestable.
    public func evaluateMerge(
        tips: [String: TestedTip],
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureMergeReport {
        var results: [RepoMergeResult] = []
        for repo in repos {
            let tip = tips[repo.name] ?? TestedTip(branch: nil)
            results.append(
                await testMerge(
                    branch: tip.branchName, recordedCommit: tip.recordedCommit, in: repo,
                    mainline: mainlines?[repo.name]
                )
            )
        }
        return FeatureMergeReport(branches: tips.compactMapValues(\.branch), results: results)
    }

    /// Test-merges a Feature Branch against a single repository's Mainline.
    public func testMerge(
        branch: FeatureBranch,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        await testMerge(branch: branch.name, in: repo, mainline: mainline)
    }

    /// Test-merges a branch name against a single repository's Mainline.
    public func testMerge(
        branch: String,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        await testMerge(branch: branch, recordedCommit: nil, in: repo, mainline: mainline)
    }

    /// Test-merges `recordedCommit` — or, only when no commit was recorded, the branch name — against a single
    /// repository's Mainline (feature-authoring/select-the-next-feature, #tested-tip). A recorded commit the
    /// repository no longer has is untestable and the branch is never consulted, so commits added to the pull
    /// request on GitHub are not part of the test. One `git merge-tree` read gives both the Mainline Conflict
    /// verdict and the content test's merged tree.
    public func testMerge(
        branch: String,
        recordedCommit: String?,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return RepoMergeResult(
                repository: repo.name,
                branch: branch,
                verdict: .untestable(reason: "repository path does not exist: \(repo.path)")
            )
        }

        // 1. Resolve the tested commit in the repository: the recorded one alone when there is one, else the branch
        let tested = await resolveTestedCommit(branch: branch, recordedCommit: recordedCommit, in: path)
        guard let branchCommit = tested.commit else {
            return RepoMergeResult(
                repository: repo.name,
                branch: branch,
                verdict: .untestable(reason: tested.unresolvedReason)
            )
        }

        // 2. Resolve mainline ref and commit SHA
        let mainlineRef: String?
        let mainlineCommit: String?
        if let mainline {
            mainlineRef = mainline.ref
            mainlineCommit = mainline.commit
        } else {
            let refresher = MainlineRefresher(git: git)
            let defaultBranch = await refresher.resolveDefaultBranch(for: repo, in: path)
            (mainlineRef, mainlineCommit) = await resolveMainlineCommit(defaultBranch: defaultBranch, in: path)
        }

        guard let targetMainlineCommit = mainlineCommit, !targetMainlineCommit.isEmpty else {
            return RepoMergeResult(
                repository: repo.name,
                branch: branch,
                verdict: .untestable(reason: "could not resolve mainline"),
                branchCommit: branchCommit
            )
        }

        // 3. Test-merge with `git merge-tree`: writes tree objects only, never a commit or ref,
        // and never touches the working tree.
        let merge = await mergeTree(mainlineCommit: targetMainlineCommit, branchCommit: branchCommit, in: path)

        // 4. The content test's other two reads (see MergeTester+ContentTest.swift), only for a clean merge.
        let content = await contentReads(
            verdict: merge.verdict, tip: branchCommit, mainline: targetMainlineCommit, in: path
        )

        return RepoMergeResult(
            repository: repo.name,
            branch: branch,
            verdict: merge.verdict,
            branchCommit: branchCommit,
            mainlineRef: mainlineRef,
            mainlineCommit: targetMainlineCommit,
            mergedTree: merge.tree,
            mainlineTree: content.mainlineTree,
            tipHasNetChange: content.tipHasNetChange
        )
    }

    private func mergeTree(
        mainlineCommit: String, branchCommit: String, in path: String
    ) async -> (verdict: MergeVerdict, tree: String?) {
        let result = await git.run([
            "-C", path,
            "merge-tree",
            "--write-tree",
            "--name-only",
            mainlineCommit,
            branchCommit
        ])

        switch result.exitCode {
        case 0:
            return (.clean, mergedTree(fromStdout: result.stdout))
        case 1:
            let paths = conflictingPaths(fromStdout: result.stdout)
            if paths.isEmpty {
                return (.untestable(reason: "merge-tree reported a conflict without paths"), nil)
            }
            return (.conflicting(paths: paths), nil)
        default:
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (.untestable(reason: "git merge-tree exited \(result.exitCode): \(stderr)"), nil)
        }
    }

    /// The result tree OID: line 1 of `git merge-tree --write-tree` stdout.
    private func mergedTree(fromStdout stdout: String) -> String? {
        let first = stdout.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? nil : first
    }

    /// Parses the conflicting paths out of `git merge-tree --write-tree --name-only` stdout.
    ///
    /// Format: line 1 is the result tree OID, then one conflicting path per line, then a blank
    /// line, then informational messages ("Auto-merging ...", "CONFLICT (...)").
    private func conflictingPaths(fromStdout stdout: String) -> [String] {
        let lines = stdout.components(separatedBy: "\n")
        guard lines.count > 1 else { return [] }

        var paths: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            paths.append(line)
        }

        if paths.isEmpty {
            for line in lines where line.hasPrefix("CONFLICT") {
                if let range = line.range(of: " in ", options: .backwards) {
                    let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !path.isEmpty { paths.append(path) }
                }
            }
        }

        return Array(Set(paths)).sorted()
    }

    /// The commit under test (#tested-tip): `recordedCommit` when one was recorded — nil if the repository no
    /// longer has it, and the branch is then never read — else the commit the branch name resolves to. The
    /// reason says which of the two could not be resolved.
    private func resolveTestedCommit(
        branch: String, recordedCommit: String?, in path: String
    ) async -> (commit: String?, unresolvedReason: String) {
        if let recordedCommit {
            return (
                await git.existingCommit(recordedCommit, in: path),
                "recorded commit \(recordedCommit) is not in the repository"
            )
        }
        return (await resolveTipBranch(branch, in: path), "could not resolve branch \(branch)")
    }

    /// The commit a branch name resolves to; nil for the empty name a tip with no Feature Branch carries.
    private func resolveTipBranch(_ branch: String, in path: String) async -> String? {
        guard !branch.isEmpty else { return nil }
        return await resolveCommit(forRef: branch, in: path)
    }

    private func resolveCommit(forRef ref: String, in path: String) async -> String? {
        // Try direct ref / commit SHA
        let probeDirect = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"
        ])
        if probeDirect.isSuccess {
            let sha = probeDirect.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        // Try local branch refs/heads/<ref>
        let probeHeads = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/\(ref)^{commit}"
        ])
        if probeHeads.isSuccess {
            let sha = probeHeads.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        // Try remote-tracking ref refs/remotes/origin/<ref>
        let probeRemotes = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(ref)^{commit}"
        ])
        if probeRemotes.isSuccess {
            let sha = probeRemotes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        return nil
    }

    private func resolveMainlineCommit(
        defaultBranch: String,
        in path: String
    ) async -> (ref: String?, commit: String?) {
        let remoteRef = "refs/remotes/origin/\(defaultBranch)"
        let probeRemote = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(remoteRef)^{commit}"
        ])
        if probeRemote.isSuccess {
            let sha = probeRemote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return (remoteRef, sha) }
        }

        let localRef = "refs/heads/\(defaultBranch)"
        let probeLocal = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(localRef)^{commit}"
        ])
        if probeLocal.isSuccess {
            let sha = probeLocal.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return (localRef, sha) }
        }

        let probeHead = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"
        ])
        if probeHead.isSuccess {
            let sha = probeHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return ("HEAD", sha) }
        }

        return (nil, nil)
    }
}
