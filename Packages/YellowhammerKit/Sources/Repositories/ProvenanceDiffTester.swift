import Domain
import Foundation

/// Tests whether recorded paths in a Transcription Block have changed between the recorded commit
/// and current mainline head.
///
/// Local Git evaluation using `git diff --name-only`. Resolves local mainline head without network access,
/// touches no working tree, index, ref or commit, and leaves git status unchanged.
public struct ProvenanceDiffTester: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Evaluates whether any recorded path changed between `recordedCommit` and `mainlineCommit`.
    public func diffPaths(
        recordedCommit: String,
        mainlineCommit: String,
        paths: [String],
        in repositoryPath: String
    ) async -> ProvenanceVerdict {
        if paths.isEmpty || recordedCommit == mainlineCommit {
            return .clean
        }

        var args = ["-C", repositoryPath, "diff", "--name-only", recordedCommit, mainlineCommit, "--"]
        args.append(contentsOf: paths)

        let result = await git.run(args)
        if result.isSuccess {
            let lines = result.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let changedPaths = Array(Set(lines)).sorted()
            return changedPaths.isEmpty ? .clean : .stale(changedPaths: changedPaths)
        } else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = stderr.isEmpty ? "git diff exited with status \(result.exitCode)" : stderr
            return .untestable(reason: reason)
        }
    }

    /// Tests provenance for a working repository.
    public func testProvenance(
        repository: Repo,
        paths: [String],
        recordedCommit: String,
        mainline: ResolvedMainline? = nil
    ) async -> RepoProvenanceResult {
        let path = (repository.path as NSString).expandingTildeInPath
        let (mainlineRef, mainlineCommit): (String?, String?)
        if let mainline {
            mainlineRef = mainline.ref
            mainlineCommit = mainline.commit
        } else {
            let refresher = MainlineRefresher(git: git)
            let defaultBranch = await refresher.resolveDefaultBranch(for: repository, in: path)
            (mainlineRef, mainlineCommit) = await resolveMainlineCommit(defaultBranch: defaultBranch, in: path)
        }

        let target = DiffTarget(
            path: path,
            repositoryName: repository.name,
            paths: paths,
            recordedCommit: recordedCommit,
            mainlineRef: mainlineRef,
            mainlineCommit: mainlineCommit,
            missingPathError: "repository path does not exist: \(repository.path)",
            missingMainlineError: "could not resolve mainline for repository \(repository.name)"
        )
        return await performDiff(target: target)
    }

    /// Tests provenance for a Spec Source.
    public func testProvenance(
        specSource: SpecSource,
        paths: [String],
        recordedCommit: String,
        mainline: ResolvedMainline? = nil,
        repositoryName: String? = nil
    ) async -> RepoProvenanceResult {
        let repoName = repositoryName ?? mainline?.repository ?? "spec_source"
        let path = (specSource.path as NSString).expandingTildeInPath
        let (mainlineRef, mainlineCommit): (String?, String?)
        if let mainline {
            mainlineRef = mainline.ref
            mainlineCommit = mainline.commit
        } else {
            let refresher = MainlineRefresher(git: git)
            let resolved = await refresher.resolveSpecSource(specSource)
            mainlineRef = resolved?.ref
            mainlineCommit = resolved?.commit
        }

        let target = DiffTarget(
            path: path,
            repositoryName: repoName,
            paths: paths,
            recordedCommit: recordedCommit,
            mainlineRef: mainlineRef,
            mainlineCommit: mainlineCommit,
            missingPathError: "spec source path does not exist: \(specSource.path)",
            missingMainlineError: "could not resolve spec source mainline"
        )
        return await performDiff(target: target)
    }

    private struct DiffTarget {
        let path: String
        let repositoryName: String
        let paths: [String]
        let recordedCommit: String
        let mainlineRef: String?
        let mainlineCommit: String?
        let missingPathError: String
        let missingMainlineError: String
    }

    private func performDiff(target: DiffTarget) async -> RepoProvenanceResult {
        guard FileManager.default.fileExists(atPath: target.path) else {
            return RepoProvenanceResult(
                repository: target.repositoryName,
                recordedPaths: target.paths,
                recordedCommit: target.recordedCommit,
                verdict: .untestable(reason: target.missingPathError)
            )
        }

        guard let targetMainlineCommit = target.mainlineCommit, !targetMainlineCommit.isEmpty else {
            return RepoProvenanceResult(
                repository: target.repositoryName,
                recordedPaths: target.paths,
                recordedCommit: target.recordedCommit,
                mainlineRef: target.mainlineRef,
                verdict: .untestable(reason: target.missingMainlineError)
            )
        }

        guard let resolvedRecordedCommit = await resolveCommitSha(target.recordedCommit, in: target.path) else {
            return RepoProvenanceResult(
                repository: target.repositoryName,
                recordedPaths: target.paths,
                recordedCommit: target.recordedCommit,
                mainlineRef: target.mainlineRef,
                mainlineCommit: targetMainlineCommit,
                verdict: .untestable(reason: "could not resolve recorded commit \(target.recordedCommit)")
            )
        }

        let verdict = await diffPaths(
            recordedCommit: resolvedRecordedCommit,
            mainlineCommit: targetMainlineCommit,
            paths: target.paths,
            in: target.path
        )

        return RepoProvenanceResult(
            repository: target.repositoryName,
            recordedPaths: target.paths,
            recordedCommit: target.recordedCommit,
            mainlineRef: target.mainlineRef,
            mainlineCommit: targetMainlineCommit,
            verdict: verdict
        )
    }

    private func resolveCommitSha(_ commitOrRef: String, in path: String) async -> String? {
        let result = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "\(commitOrRef)^{commit}"
        ])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
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

// MARK: - Transcription Block & Brief Evaluation

extension ProvenanceDiffTester {
    /// Tests a Transcription Block against a working repository.
    public func testTranscriptionBlock(
        _ block: TranscriptionBlock,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoProvenanceResult {
        if block.authorSupplied || block.mainlineCommit == nil || block.mainlineCommit?.isEmpty == true {
            return RepoProvenanceResult(
                repository: block.repository,
                recordedPaths: block.paths,
                recordedCommit: block.mainlineCommit,
                mainlineRef: mainline?.ref,
                mainlineCommit: mainline?.commit,
                verdict: .operatorSupplied
            )
        }

        return await testProvenance(
            repository: repo,
            paths: block.paths,
            recordedCommit: block.mainlineCommit!,
            mainline: mainline
        )
    }

    /// Tests a Transcription Block against a Spec Source.
    public func testTranscriptionBlock(
        _ block: TranscriptionBlock,
        in specSource: SpecSource,
        mainline: ResolvedMainline? = nil
    ) async -> RepoProvenanceResult {
        if block.authorSupplied || block.mainlineCommit == nil || block.mainlineCommit?.isEmpty == true {
            return RepoProvenanceResult(
                repository: block.repository,
                recordedPaths: block.paths,
                recordedCommit: block.mainlineCommit,
                mainlineRef: mainline?.ref,
                mainlineCommit: mainline?.commit,
                verdict: .operatorSupplied
            )
        }

        return await testProvenance(
            specSource: specSource,
            paths: block.paths,
            recordedCommit: block.mainlineCommit!,
            mainline: mainline,
            repositoryName: block.repository
        )
    }

    /// Tests a Transcription Block within a Project's configured repositories.
    public func testTranscriptionBlock(
        _ block: TranscriptionBlock,
        projectRepositories: ProjectRepositories,
        mainlines: ResolvedMainlines? = nil
    ) async -> RepoProvenanceResult {
        if block.authorSupplied || block.mainlineCommit == nil || block.mainlineCommit?.isEmpty == true {
            let resolved = mainlines?[block.repository]
                ?? ((block.repository == "spec_source" || block.repository == "spec") ? mainlines?.specSource : nil)
            return RepoProvenanceResult(
                repository: block.repository,
                recordedPaths: block.paths,
                recordedCommit: block.mainlineCommit,
                mainlineRef: resolved?.ref,
                mainlineCommit: resolved?.commit,
                verdict: .operatorSupplied
            )
        }

        if let repo = projectRepositories.workingRepos.first(where: { $0.name == block.repository }) {
            let mainline = mainlines?[repo.name]
            return await testTranscriptionBlock(block, in: repo, mainline: mainline)
        }

        if let specSource = projectRepositories.specSource,
           block.repository == "spec_source" || block.repository == "spec" {
            let mainline = mainlines?.specSource
            return await testTranscriptionBlock(block, in: specSource, mainline: mainline)
        }

        return RepoProvenanceResult(
            repository: block.repository,
            recordedPaths: block.paths,
            recordedCommit: block.mainlineCommit,
            mainlineRef: nil,
            mainlineCommit: nil,
            verdict: .untestable(reason: "repository \(block.repository) is not configured in this Project")
        )
    }

    /// Evaluates an Architectural Brief against a Project's configured repositories.
    public func evaluateBrief(
        _ brief: ArchitecturalBrief,
        projectRepositories: ProjectRepositories,
        mainlines: ResolvedMainlines? = nil
    ) async -> CardProvenanceReport {
        await evaluateTranscriptionBlocks(
            brief.transcriptions,
            projectRepositories: projectRepositories,
            mainlines: mainlines
        )
    }

    /// Evaluates an Architectural Brief against an explicit set of working repos and optional spec source.
    public func evaluateBrief(
        _ brief: ArchitecturalBrief,
        repos: [Repo],
        specSource: SpecSource? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> CardProvenanceReport {
        let projectRepositories = ProjectRepositories(workingRepos: repos, specSource: specSource)
        return await evaluateTranscriptionBlocks(
            brief.transcriptions,
            projectRepositories: projectRepositories,
            mainlines: mainlines
        )
    }

    /// Evaluates a collection of Transcription Blocks against a Project's configured repositories.
    public func evaluateTranscriptionBlocks(
        _ blocks: [TranscriptionBlock],
        projectRepositories: ProjectRepositories,
        mainlines: ResolvedMainlines? = nil
    ) async -> CardProvenanceReport {
        var results: [RepoProvenanceResult] = []
        for block in blocks {
            let result = await testTranscriptionBlock(
                block,
                projectRepositories: projectRepositories,
                mainlines: mainlines
            )
            results.append(result)
        }
        return CardProvenanceReport(results: results)
    }

    /// Evaluates a collection of Transcription Blocks against an explicit set of working repos and optional spec source.
    public func evaluateTranscriptionBlocks(
        _ blocks: [TranscriptionBlock],
        repos: [Repo],
        specSource: SpecSource? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> CardProvenanceReport {
        let projectRepositories = ProjectRepositories(workingRepos: repos, specSource: specSource)
        return await evaluateTranscriptionBlocks(
            blocks,
            projectRepositories: projectRepositories,
            mainlines: mainlines
        )
    }
}

public typealias ProvenanceTester = ProvenanceDiffTester
