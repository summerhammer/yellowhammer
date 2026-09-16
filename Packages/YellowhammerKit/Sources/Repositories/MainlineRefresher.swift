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
        guard FileManager.default.fileExists(atPath: path) else {
            return (nil, nil)
        }

        let hasOrigin = await hasRemote(named: "origin", in: path)
        let defaultBranch = await resolveDefaultBranch(for: repo, in: path)

        if !hasOrigin {
            // With no remote, resolve local default branch without fetching.
            let (ref, commit) = await resolveLocalCommit(defaultBranch: defaultBranch, in: path)
            guard let commit else { return (nil, nil) }
            let mainline = ResolvedMainline(
                repository: repo.name,
                defaultBranch: defaultBranch,
                ref: ref,
                commit: commit
            )
            return (mainline, nil)
        }

        // Perform opportunistic non-destructive fetch with 10s transport timeout.
        let fetchArgs = [
            "-c", "transfer.timeout=10",
            "-C", path,
            "fetch",
            "--quiet",
            "origin",
            defaultBranch
        ]
        let fetchResult = await git.run(fetchArgs, timeout: 15.0)

        if fetchResult.isSuccess {
            // Fetch succeeded: resolve commit SHA for refs/remotes/origin/<default_branch>
            let remoteRef = "refs/remotes/origin/\(defaultBranch)"
            let shaResult = await git.run([
                "-C", path, "rev-parse", "--verify", "--quiet", "\(remoteRef)^{commit}"
            ])
            if shaResult.isSuccess {
                let commit = shaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !commit.isEmpty {
                    let mainline = ResolvedMainline(
                        repository: repo.name,
                        defaultBranch: defaultBranch,
                        ref: remoteRef,
                        commit: commit
                    )
                    return (mainline, nil)
                }
            }

            // Fallback if remote ref wasn't populated
            let (ref, commit) = await resolveLocalCommit(defaultBranch: defaultBranch, in: path)
            if let commit {
                let mainline = ResolvedMainline(
                    repository: repo.name,
                    defaultBranch: defaultBranch,
                    ref: ref,
                    commit: commit
                )
                return (mainline, nil)
            }
            return (nil, nil)
        } else {
            // Fetch failed: record failure and continue on cached ref.
            let rawStderr = fetchResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = rawStderr.isEmpty ? "git fetch exited with status \(fetchResult.exitCode)" : rawStderr
            let failure = MainlineFetchFailure(repository: repo.name, reason: reason)

            // 1. Probe cached refs/remotes/origin/<default_branch>
            let remoteRef = "refs/remotes/origin/\(defaultBranch)"
            let cachedResult = await git.run([
                "-C", path, "rev-parse", "--verify", "--quiet", "\(remoteRef)^{commit}"
            ])
            if cachedResult.isSuccess {
                let commit = cachedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !commit.isEmpty {
                    let mainline = ResolvedMainline(
                        repository: repo.name,
                        defaultBranch: defaultBranch,
                        ref: remoteRef,
                        commit: commit
                    )
                    return (mainline, failure)
                }
            }

            // 2. Fallback to local default branch
            let (ref, commit) = await resolveLocalCommit(defaultBranch: defaultBranch, in: path)
            if let commit {
                let mainline = ResolvedMainline(
                    repository: repo.name,
                    defaultBranch: defaultBranch,
                    ref: ref,
                    commit: commit
                )
                return (mainline, failure)
            }

            return (nil, failure)
        }
    }

    /// Resolves the Spec Source's current HEAD without fetching or writing anything.
    public func resolveSpecSource(_ specSource: SpecSource) async -> ResolvedMainline? {
        let path = (specSource.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        // 1. Resolve default branch for Spec Source
        let defaultBranch: String
        if let override = specSource.defaultBranch, !override.isEmpty {
            defaultBranch = override
        } else {
            let symResult = await git.run(["-C", path, "symbolic-ref", "HEAD"])
            if symResult.isSuccess {
                let trimmed = symResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("refs/heads/") {
                    defaultBranch = String(trimmed.dropFirst("refs/heads/".count))
                } else {
                    defaultBranch = "main"
                }
            } else {
                let probeMain = await git.run([
                    "-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"
                ])
                if probeMain.isSuccess && !probeMain.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    defaultBranch = "main"
                } else {
                    let probeMaster = await git.run([
                        "-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/master^{commit}"
                    ])
                    if probeMaster.isSuccess
                        && !probeMaster.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        defaultBranch = "master"
                    } else {
                        defaultBranch = "main"
                    }
                }
            }
        }

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

    /// Resolves the default branch for a working repository according to the spec's precedence order:
    /// 1. Explicit default branch override if specified.
    /// 2. `git symbolic-ref refs/remotes/origin/HEAD` -> strip `refs/remotes/origin/`.
    /// 3. Else probe `refs/remotes/origin/main`.
    /// 4. Else probe `refs/remotes/origin/master`.
    /// 5. With no remote, resolve local default branch (`git symbolic-ref HEAD` or probe local `main`/`master`).
    public func resolveDefaultBranch(for repo: Repo, in path: String) async -> String {
        // 1. Explicit default branch override
        if let override = repo.defaultBranch, !override.isEmpty {
            return override
        }

        // 2. git symbolic-ref refs/remotes/origin/HEAD
        let symRefResult = await git.run(["-C", path, "symbolic-ref", "refs/remotes/origin/HEAD"])
        if symRefResult.isSuccess {
            let trimmed = symRefResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("refs/remotes/origin/") {
                let branch = String(trimmed.dropFirst("refs/remotes/origin/".count))
                if !branch.isEmpty { return branch }
            } else if trimmed.hasPrefix("origin/") {
                let branch = String(trimmed.dropFirst("origin/".count))
                if !branch.isEmpty { return branch }
            }
        }

        // 3. Probe refs/remotes/origin/main
        let probeOriginMain = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"
        ])
        if probeOriginMain.isSuccess
            && !probeOriginMain.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "main"
        }

        // 4. Probe refs/remotes/origin/master
        let probeOriginMaster = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/master^{commit}"
        ])
        if probeOriginMaster.isSuccess
            && !probeOriginMaster.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "master"
        }

        // 5. With no remote, resolve local default branch
        let localSymResult = await git.run(["-C", path, "symbolic-ref", "HEAD"])
        if localSymResult.isSuccess {
            let trimmed = localSymResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("refs/heads/") {
                let branch = String(trimmed.dropFirst("refs/heads/".count))
                if !branch.isEmpty { return branch }
            }
        }

        let probeLocalMain = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"
        ])
        if probeLocalMain.isSuccess
            && !probeLocalMain.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "main"
        }

        let probeLocalMaster = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/master^{commit}"
        ])
        if probeLocalMaster.isSuccess
            && !probeLocalMaster.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "master"
        }

        return "main"
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
