import Domain
import Foundation

/// A failure to fetch a working repository's mainline during opportunistic refresh.
public struct MainlineFetchFailure: Equatable, Sendable {
    public let repository: String
    public let reason: String

    public init(repository: String, reason: String) {
        self.repository = repository
        self.reason = reason
    }
}

/// The result of refreshing a Project's repositories at Act start.
public struct MainlineRefreshResult: Sendable {
    public let mainlines: ResolvedMainlines
    public let failures: [MainlineFetchFailure]

    public init(mainlines: ResolvedMainlines, failures: [MainlineFetchFailure] = []) {
        self.mainlines = mainlines
        self.failures = failures
    }
}

/// Refreshes working repositories' remote-tracking mainlines at Act start and resolves Spec Source HEAD.
///
/// Opportunistic non-destructive fetch runs at the start of each author, build, and land Act.
/// If fetch fails (offline or unreachable), it falls back gracefully to cached refs without failing
/// the Act and records a ``MainlineFetchFailure``. A Spec Source is never fetched and never written.
public struct MainlineRefresher: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Refreshes all repositories for a Project: working repositories (opportunistic fetch) and Spec Source (local read).
    public func refresh(repositories: ProjectRepositories) async -> MainlineRefreshResult {
        var workingMainlines: [String: ResolvedMainline] = [:]
        var failures: [MainlineFetchFailure] = []

        for repo in repositories.workingRepos {
            let (mainline, failure) = await refreshWorkingRepo(repo)
            if let mainline {
                workingMainlines[repo.name] = mainline
            }
            if let failure {
                failures.append(failure)
            }
        }

        let specMainline: ResolvedMainline?
        if let specSource = repositories.specSource {
            specMainline = await resolveSpecSource(specSource)
        } else {
            specMainline = nil
        }

        let mainlines = ResolvedMainlines(workingRepos: workingMainlines, specSource: specMainline)
        return MainlineRefreshResult(mainlines: mainlines, failures: failures)
    }

    /// Refreshes a single working repository.
    public func refreshWorkingRepo(
        _ repo: Repo
    ) async -> (mainline: ResolvedMainline?, failure: MainlineFetchFailure?) {
        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return (nil, nil) }

        let defaultBranch = await resolveDefaultBranch(for: repo, in: path)
        if await !hasRemote(named: "origin", in: path) {
            return (await localMainline(for: repo, branch: defaultBranch, in: path), nil)
        }

        let fetchResult = await git.run([
            "-c", "transfer.timeout=10", "-C", path, "fetch", "--quiet", "origin", defaultBranch
        ], timeout: 15.0)
        if fetchResult.isSuccess {
            let remote = await remoteMainline(for: repo, branch: defaultBranch, in: path)
            if let remote { return (remote, nil) }
            return (await localMainline(for: repo, branch: defaultBranch, in: path), nil)
        }

        let rawStderr = fetchResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = rawStderr.isEmpty ? "git fetch exited with status \(fetchResult.exitCode)" : rawStderr
        let failure = MainlineFetchFailure(repository: repo.name, reason: reason)
        let cached = await remoteMainline(for: repo, branch: defaultBranch, in: path)
        if let cached { return (cached, failure) }
        return (await localMainline(for: repo, branch: defaultBranch, in: path), failure)
    }

    private func remoteMainline(for repo: Repo, branch: String, in path: String) async -> ResolvedMainline? {
        let ref = "refs/remotes/origin/\(branch)"
        return await mainline(for: repo.name, branch: branch, ref: ref, in: path)
    }

    private func localMainline(for repo: Repo, branch: String, in path: String) async -> ResolvedMainline? {
        let (ref, commit) = await resolveLocalCommit(defaultBranch: branch, in: path)
        guard let commit else { return nil }
        return ResolvedMainline(repository: repo.name, defaultBranch: branch, ref: ref, commit: commit)
    }

    private func mainline(
        for repository: String, branch: String, ref: String, in path: String
    ) async -> ResolvedMainline? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        guard result.isSuccess else { return nil }
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { return nil }
        return ResolvedMainline(repository: repository, defaultBranch: branch, ref: ref, commit: commit)
    }

    /// Resolves the Spec Source's current HEAD without fetching or writing anything.
    public func resolveSpecSource(_ specSource: SpecSource) async -> ResolvedMainline? {
        let path = (specSource.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let defaultBranch = await resolveSpecDefaultBranch(specSource, in: path)

        // 2. Read local checkout's current head: refs/heads/<default_branch> or HEAD
        let branchRef = "refs/heads/\(defaultBranch)"
        let branchShaResult = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(branchRef)^{commit}"
        ])
        if branchShaResult.isSuccess {
            let commit = branchShaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !commit.isEmpty {
                return ResolvedMainline(
                    repository: "spec_source",
                    defaultBranch: defaultBranch,
                    ref: branchRef,
                    commit: commit
                )
            }
        }

        // Fallback to HEAD
        let headShaResult = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"
        ])
        if headShaResult.isSuccess {
            let commit = headShaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !commit.isEmpty {
                return ResolvedMainline(
                    repository: "spec_source",
                    defaultBranch: defaultBranch,
                    ref: "HEAD",
                    commit: commit
                )
            }
        }

        return nil
    }

    private func resolveSpecDefaultBranch(_ source: SpecSource, in path: String) async -> String {
        if let override = source.defaultBranch, !override.isEmpty { return override }
        let symbolic = await git.run(["-C", path, "symbolic-ref", "HEAD"])
        if symbolic.isSuccess {
            let branch = symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.hasPrefix("refs/heads/") { return String(branch.dropFirst("refs/heads/".count)) }
            return "main"
        }
        if await refExists("refs/heads/main", in: path) { return "main" }
        if await refExists("refs/heads/master", in: path) { return "master" }
        return "main"
    }

    /// Resolves the default branch according to the configured override, remote HEAD,
    /// remote main/master refs, then local HEAD and main/master refs.
    public func resolveDefaultBranch(for repo: Repo, in path: String) async -> String {
        if let override = repo.defaultBranch, !override.isEmpty { return override }
        if let branch = await symbolicBranch(
            "refs/remotes/origin/HEAD", prefixes: ["refs/remotes/origin/", "origin/"], in: path
        ) {
            return branch
        }
        if await refExists("refs/remotes/origin/main", in: path) { return "main" }
        if await refExists("refs/remotes/origin/master", in: path) { return "master" }
        if let branch = await symbolicBranch("HEAD", prefixes: ["refs/heads/"], in: path) { return branch }
        if await refExists("refs/heads/main", in: path) { return "main" }
        if await refExists("refs/heads/master", in: path) { return "master" }
        return "main"
    }

    private func symbolicBranch(_ ref: String, prefixes: [String], in path: String) async -> String? {
        let result = await git.run(["-C", path, "symbolic-ref", ref])
        guard result.isSuccess else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes where value.hasPrefix(prefix) {
            let branch = String(value.dropFirst(prefix.count))
            if !branch.isEmpty { return branch }
        }
        return nil
    }

    private func refExists(_ ref: String, in path: String) async -> Bool {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        return result.isSuccess && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasRemote(named remoteName: String, in path: String) async -> Bool {
        let result = await git.run(["-C", path, "remote"])
        guard result.isSuccess else { return false }
        let remotes = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return remotes.contains(remoteName)
    }

    private func resolveLocalCommit(
        defaultBranch: String,
        in path: String
    ) async -> (ref: String, commit: String?) {
        let branchRef = "refs/heads/\(defaultBranch)"
        let branchResult = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(branchRef)^{commit}"
        ])
        if branchResult.isSuccess {
            let commit = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !commit.isEmpty {
                return (branchRef, commit)
            }
        }

        let headResult = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"
        ])
        if headResult.isSuccess {
            let commit = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !commit.isEmpty {
                return ("HEAD", commit)
            }
        }

        return (branchRef, nil)
    }
}
