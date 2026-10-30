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
    /// The tree OID `git merge-tree --write-tree` printed for a clean merge into `mainlineCommit`; nil for any
    /// other verdict.
    public let mergedTree: String?
    /// Whether the tip's tree differs from the tree of `git merge-base <mainline> <tip>` (the fork point) — the
    /// branch has a net change at all (#net-zero-branch). Read only by the content test
    /// (``MergeTester/testContent(branch:recordedCommit:in:mainline:)``); nil otherwise, or when it could not be
    /// read.
    public let tipHasNetChange: Bool?
    /// The content test's landing commit: the oldest commit C on mainline's first-parent chain after the fork
    /// point such that `git merge-tree --write-tree C <tip>` exits clean and writes C's own tree — merging the
    /// tip into C changes nothing, so C is where the branch's change entered mainline. Searched only by the
    /// content test, and only for a tip with a net change; nil when no such commit exists.
    public let landingCommit: String?

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

    /// Whether mainline's history shows the tip's net change although the tip is not an ancestor of it — a
    /// Squash and merge or Rebase and merge (feature-authoring/select-the-next-feature, #merge-test): the tip
    /// has a net change, and the content test found the commit where it entered mainline. That commit need not
    /// be mainline's head, so a later edit to the same lines does not hide the merge (OQ190 item 24). A branch
    /// with no net change (a commit and its revert) is never merged, though some commit would absorb it.
    public var isContentMerged: Bool {
        tipHasNetChange == true && landingCommit != nil
    }

    public init(
        repository: String,
        branch: String,
        verdict: MergeVerdict,
        branchCommit: String? = nil,
        mainlineRef: String? = nil,
        mainlineCommit: String? = nil,
        mergedTree: String? = nil,
        tipHasNetChange: Bool? = nil,
        landingCommit: String? = nil
    ) {
        self.repository = repository
        self.branch = branch
        self.verdict = verdict
        self.branchCommit = branchCommit
        self.mainlineRef = mainlineRef
        self.mainlineCommit = mainlineCommit
        self.mergedTree = mergedTree
        self.tipHasNetChange = tipHasNetChange
        self.landingCommit = landingCommit
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
    /// request on GitHub are not part of the test. One `git merge-tree` read of mainline's head gives the
    /// Mainline Conflict verdict; the content test is
    /// ``testContent(branch:recordedCommit:in:mainline:)``.
    public func testMerge(
        branch: String,
        recordedCommit: String?,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        let read: ResolvedMergeRead
        switch await resolveMergeRead(branch: branch, recordedCommit: recordedCommit, in: repo, mainline: mainline) {
        case .resolved(let resolved): read = resolved
        case .untestable(let result): return result
        }

        // Test-merge with `git merge-tree`: writes tree objects only, never a commit or ref, and never touches
        // the working tree.
        let merge = await mergeTree(mainlineCommit: read.mainlineCommit, branchCommit: read.branchCommit, in: read.path)
        return read.result(verdict: merge.verdict, mergedTree: merge.tree)
    }

    /// `git merge-tree --write-tree --name-only <into> <tip>`: the verdict, and the merged tree for a clean merge.
    func mergeTree(
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
}
