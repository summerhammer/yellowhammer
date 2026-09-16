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

    public init(
        repository: String,
        branch: String,
        verdict: MergeVerdict,
        branchCommit: String? = nil,
        mainlineRef: String? = nil,
        mainlineCommit: String? = nil
    ) {
        self.repository = repository
        self.branch = branch
        self.verdict = verdict
        self.branchCommit = branchCommit
        self.mainlineRef = mainlineRef
        self.mainlineCommit = mainlineCommit
    }
}

/// A report of merge tests for a Feature Branch across all repositories touched by a Feature.
public struct FeatureMergeReport: Equatable, Sendable {
    public let branch: FeatureBranch
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
        branch: FeatureBranch,
        results: [RepoMergeResult]
    ) {
        self.branch = branch
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

    /// Evaluates the merge test for a Feature Branch across all repositories touched by the Feature.
    public func evaluateMerge(
        branch: FeatureBranch,
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureMergeReport {
        var results: [RepoMergeResult] = []
        for repo in repos {
            let mainline = mainlines?[repo.name]
            let result = await testMerge(branch: branch.name, in: repo, mainline: mainline)
            results.append(result)
        }
        return FeatureMergeReport(branch: branch, results: results)
    }

    /// Evaluates the merge test for a branch name across all repositories touched by the Feature.
    public func evaluateMerge(
        branchName: String,
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureMergeReport {
        await evaluateMerge(
            branch: FeatureBranch(name: branchName),
            repos: repos,
            mainlines: mainlines
        )
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
        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return RepoMergeResult(
                repository: repo.name,
                branch: branch,
                verdict: .untestable(reason: "repository path does not exist: \(repo.path)")
            )
        }

        // 1. Resolve branch commit SHA in the repository
        guard let branchCommit = await resolveCommit(forRef: branch, in: path) else {
            return RepoMergeResult(
                repository: repo.name,
                branch: branch,
                verdict: .untestable(reason: "could not resolve branch \(branch)")
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
        let verdict = await mergeTree(mainlineCommit: targetMainlineCommit, branchCommit: branchCommit, in: path)

        return RepoMergeResult(
            repository: repo.name,
            branch: branch,
            verdict: verdict,
            branchCommit: branchCommit,
            mainlineRef: mainlineRef,
            mainlineCommit: targetMainlineCommit
        )
    }

    private func mergeTree(mainlineCommit: String, branchCommit: String, in path: String) async -> MergeVerdict {
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
            return .clean
        case 1:
            let paths = conflictingPaths(fromStdout: result.stdout)
            if paths.isEmpty {
                return .untestable(reason: "merge-tree reported a conflict without paths")
            }
            return .conflicting(paths: paths)
        default:
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .untestable(reason: "git merge-tree exited \(result.exitCode): \(stderr)")
        }
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
