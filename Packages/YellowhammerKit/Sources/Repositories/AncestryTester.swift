import Domain
import Foundation

/// The result of an ancestry test for a single repository.
public struct RepoAncestryResult: Equatable, Sendable {
    public let repository: String
    public let branch: String
    public let isAncestor: Bool
    public let branchCommit: String?
    public let mainlineCommit: String?

    public init(
        repository: String,
        branch: String,
        isAncestor: Bool,
        branchCommit: String? = nil,
        mainlineCommit: String? = nil
    ) {
        self.repository = repository
        self.branch = branch
        self.isAncestor = isAncestor
        self.branchCommit = branchCommit
        self.mainlineCommit = mainlineCommit
    }
}

/// A report of ancestry checks for a Feature Branch across all repositories touched by a Feature.
public struct FeatureAncestryReport: Equatable, Sendable {
    public let branch: FeatureBranch
    public let results: [RepoAncestryResult]
    public let mergedFraction: MergedFraction

    /// Whether all touched repositories have merged the Feature Branch into mainline.
    public var isAllMerged: Bool {
        mergedFraction.isFullyMerged
    }

    /// Repositories whose mainline does not yet contain the Feature Branch.
    public var unmergedRepositories: [String] {
        results.filter { !$0.isAncestor }.map(\.repository)
    }

    /// Repositories whose mainline contains the Feature Branch.
    public var mergedRepositories: [String] {
        results.filter(\.isAncestor).map(\.repository)
    }

    public subscript(repositoryName: String) -> RepoAncestryResult? {
        results.first { $0.repository == repositoryName }
    }

    public subscript(repo: Repo) -> RepoAncestryResult? {
        results.first { $0.repository == repo.name }
    }

    public init(
        branch: FeatureBranch,
        results: [RepoAncestryResult]
    ) {
        self.branch = branch
        self.results = results
        let merged = results.filter(\.isAncestor).count
        self.mergedFraction = MergedFraction(mergedCount: merged, totalCount: results.count)
    }
}

/// Tests whether a Feature Branch is an ancestor of a repository's mainline.
///
/// Pure local Git evaluation using `git merge-base --is-ancestor`. Never reads the forge (GitHub)
/// and requires no network access.
public struct AncestryTester: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Evaluates ancestry for a Feature Branch across all repositories touched by the Feature.
    public func evaluateAncestry(
        branch: FeatureBranch,
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureAncestryReport {
        var results: [RepoAncestryResult] = []
        for repo in repos {
            let mainline = mainlines?[repo.name]
            let result = await testAncestry(branch: branch.name, in: repo, mainline: mainline)
            results.append(result)
        }
        return FeatureAncestryReport(branch: branch, results: results)
    }

    /// Evaluates ancestry for a branch name across all repositories touched by the Feature.
    public func evaluateAncestry(
        branchName: String,
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureAncestryReport {
        await evaluateAncestry(
            branch: FeatureBranch(name: branchName),
            repos: repos,
            mainlines: mainlines
        )
    }

    /// Tests whether a Feature Branch is an ancestor of a single repository's mainline.
    public func testAncestry(
        branch: FeatureBranch,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoAncestryResult {
        await testAncestry(branch: branch.name, in: repo, mainline: mainline)
    }

    /// Tests whether a branch name is an ancestor of a single repository's mainline.
    public func testAncestry(
        branch: String,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoAncestryResult {
        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return RepoAncestryResult(
                repository: repo.name,
                branch: branch,
                isAncestor: false,
                branchCommit: nil,
                mainlineCommit: nil
            )
        }

        // 1. Resolve branch commit SHA in the repository
        guard let branchCommit = await resolveCommit(forRef: branch, in: path) else {
            return RepoAncestryResult(
                repository: repo.name,
                branch: branch,
                isAncestor: false,
                branchCommit: nil,
                mainlineCommit: nil
            )
        }

        // 2. Resolve mainline commit SHA
        let mainlineCommit: String?
        if let mainline {
            mainlineCommit = mainline.commit
        } else {
            let refresher = MainlineRefresher(git: git)
            let defaultBranch = await refresher.resolveDefaultBranch(for: repo, in: path)
            mainlineCommit = await resolveMainlineCommit(defaultBranch: defaultBranch, in: path)
        }

        guard let targetMainlineCommit = mainlineCommit, !targetMainlineCommit.isEmpty else {
            return RepoAncestryResult(
                repository: repo.name,
                branch: branch,
                isAncestor: false,
                branchCommit: branchCommit,
                mainlineCommit: nil
            )
        }

        // 3. Test git merge-base --is-ancestor <branchCommit> <mainlineCommit>
        let ancestor = await isAncestor(
            ancestorCommitOrRef: branchCommit,
            of: targetMainlineCommit,
            in: path
        )

        return RepoAncestryResult(
            repository: repo.name,
            branch: branch,
            isAncestor: ancestor,
            branchCommit: branchCommit,
            mainlineCommit: targetMainlineCommit
        )
    }

    /// Low-level check whether `ancestorCommitOrRef` is an ancestor of `descendantCommitOrRef`.
    public func isAncestor(
        ancestorCommitOrRef: String,
        of descendantCommitOrRef: String,
        in repositoryPath: String
    ) async -> Bool {
        let result = await git.run([
            "-C", repositoryPath,
            "merge-base",
            "--is-ancestor",
            ancestorCommitOrRef,
            descendantCommitOrRef
        ])
        return result.exitCode == 0
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

    private func resolveMainlineCommit(defaultBranch: String, in path: String) async -> String? {
        let remoteRef = "refs/remotes/origin/\(defaultBranch)"
        let probeRemote = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(remoteRef)^{commit}"
        ])
        if probeRemote.isSuccess {
            let sha = probeRemote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        let localRef = "refs/heads/\(defaultBranch)"
        let probeLocal = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(localRef)^{commit}"
        ])
        if probeLocal.isSuccess {
            let sha = probeLocal.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        let probeHead = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"
        ])
        if probeHead.isSuccess {
            let sha = probeHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }

        return nil
    }
}
