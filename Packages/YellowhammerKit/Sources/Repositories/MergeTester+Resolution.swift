import Domain
import Foundation

// What every merge read resolves before it runs `git merge-tree` (feature-authoring/select-the-next-feature,
// #tested-tip): the repository's path, the tested commit and mainline. Split out of MergeTester.swift for the file
// and type length limits.

extension MergeTester {
    /// What every merge read resolves before it runs `git merge-tree`: the repository's path, the tested commit
    /// and mainline.
    struct ResolvedMergeRead {
        let repository: String
        let branch: String
        let path: String
        let branchCommit: String
        let mainlineRef: String?
        let mainlineCommit: String

        func result(
            verdict: MergeVerdict, mergedTree: String?, tipHasNetChange: Bool? = nil, landingCommit: String? = nil
        ) -> RepoMergeResult {
            RepoMergeResult(
                repository: repository, branch: branch, verdict: verdict, branchCommit: branchCommit,
                mainlineRef: mainlineRef, mainlineCommit: mainlineCommit, mergedTree: mergedTree,
                tipHasNetChange: tipHasNetChange, landingCommit: landingCommit
            )
        }
    }

    enum MergeReadResolution {
        case resolved(ResolvedMergeRead)
        case untestable(RepoMergeResult)
    }

    /// Resolves the repository's path, the tested commit (the recorded one alone when there is one, else the
    /// branch) and mainline (the snapshot given, else the remote-tracking default branch, else the local one,
    /// else HEAD). Whatever cannot be resolved is an untestable result.
    func resolveMergeRead(
        branch: String, recordedCommit: String?, in repo: Repo, mainline: ResolvedMainline?
    ) async -> MergeReadResolution {
        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .untestable(
                RepoMergeResult(
                    repository: repo.name, branch: branch,
                    verdict: .untestable(reason: "repository path does not exist: \(repo.path)")
                )
            )
        }

        let tested = await resolveTestedCommit(branch: branch, recordedCommit: recordedCommit, in: path)
        guard let branchCommit = tested.commit else {
            return .untestable(
                RepoMergeResult(
                    repository: repo.name, branch: branch, verdict: .untestable(reason: tested.unresolvedReason)
                )
            )
        }

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
        guard let mainlineCommit, !mainlineCommit.isEmpty else {
            return .untestable(
                RepoMergeResult(
                    repository: repo.name, branch: branch, verdict: .untestable(reason: "could not resolve mainline"),
                    branchCommit: branchCommit
                )
            )
        }
        return .resolved(
            ResolvedMergeRead(
                repository: repo.name, branch: branch, path: path, branchCommit: branchCommit,
                mainlineRef: mainlineRef, mainlineCommit: mainlineCommit
            )
        )
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
