import Domain
import Foundation

/// What saving a held Worktree's uncommitted changes as a snapshot did.
public enum UncommittedSnapshotResult: Equatable, Sendable {
    /// Nothing is uncommitted: nothing was written.
    case clean
    /// An earlier firing already saved this exact tree at `ref`: nothing was written this time.
    case alreadySnapshotted(ref: String)
    /// The changes were saved at `ref` as `commit`. `chained` is true when an earlier snapshot, now a second parent,
    /// was kept reachable.
    case snapshotted(ref: String, commit: String, modified: Int, untracked: Int, chained: Bool)
    /// git could not read the Worktree or write the snapshot; the reason says why.
    case failed(reason: String)
}

/// Whether a Worktree has uncommitted changes.
public enum WorktreeDirtiness: Equatable, Sendable {
    case clean
    case dirty
    case failed(reason: String)
}

/// The local git behind the uncommitted-changes snapshot (spec: landing/open-one-pull-request-per-repository,
/// `#uncommitted-snapshot`; OQ196 item 1): before a held Worktree is released, its modified tracked files and its
/// untracked files that git does not ignore are saved as one commit under `refs/yellowhammer/snapshot/<branch>`,
/// outside `refs/heads/`. That ref is distinct from `refs/yellowhammer/wip/<branch>` (WIP commits) and
/// `refs/yellowhammer/unpublished/<branch>` (the HEAD pin).
///
/// The snapshot moves no branch, HEAD, index or file: the tree is built in a temporary index file, never the
/// Worktree's own. It is never pushed and the engine never deletes it. `refs/yellowhammer/*` keeps no reflog, so a
/// changed snapshot names the previous one as a second parent rather than overwriting it. Local git, not behind a Port.
public struct UncommittedSnapshot: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The snapshot ref for `branch`; always fully qualified, as branch names may carry a `/`.
    public static func ref(for branch: FeatureBranch) -> String {
        "refs/yellowhammer/snapshot/\(branch.name)"
    }

    /// Whether the Worktree at `worktreePath` has uncommitted changes, for a Worktree with no Feature Branch recorded.
    public func isDirty(worktreePath: String) async -> WorktreeDirtiness {
        switch await status(worktreePath: worktreePath) {
        case .failure(let reason): .failed(reason: reason)
        case .success(let lines): lines.isEmpty ? .clean : .dirty
        }
    }

    /// Saves the uncommitted changes of the Worktree at `worktreePath` under ``ref(for:)``.
    ///
    /// The temporary index starts as a copy of the Worktree's own index, so staged changes (a force-added ignored
    /// file included) are part of the snapshot. When the staged content differs from both HEAD and the working tree,
    /// it is kept as an index commit, a parent of the snapshot, as `git stash` keeps its index commit.
    public func snapshot(worktreePath: String, branch: FeatureBranch) async -> UncommittedSnapshotResult {
        let lines: [String]
        switch await status(worktreePath: worktreePath) {
        case .failure(let reason): return .failed(reason: reason)
        case .success(let read): lines = read
        }
        guard !lines.isEmpty else { return .clean }
        let untracked = lines.filter { $0.hasPrefix("??") }.count
        let modified = lines.count - untracked

        let trees: SnapshotTrees
        switch await buildTrees(worktreePath: worktreePath) {
        case .failure(let reason): return .failed(reason: reason)
        case .success(let built): trees = built
        }
        guard trees.work != trees.head || trees.keptIndex != nil else { return .clean }

        let ref = Self.ref(for: branch)
        let existing = await resolve(["\(ref)^{commit}"], worktreePath: worktreePath)
        if let existing, await isSame(existing, as: trees, worktreePath: worktreePath) {
            return .alreadySnapshotted(ref: ref)
        }
        switch await write(trees, chaining: existing, branch: branch, worktreePath: worktreePath) {
        case .failure(let reason):
            return .failed(reason: reason)
        case .success(let commit):
            let updated = await git.run(["-C", worktreePath, "update-ref", ref, commit])
            guard updated.isSuccess else {
                return .failed(reason: updated.failureReason(fallback: "git update-ref exited \(updated.exitCode)"))
            }
            return .snapshotted(
                ref: ref, commit: commit, modified: modified, untracked: untracked, chained: existing != nil
            )
        }
    }

    /// Writes the snapshot commit: parents HEAD, then the index commit when the staged tree is kept, then the earlier
    /// snapshot when there is one, so that it stays reachable (`refs/yellowhammer/*` keeps no reflog).
    private func write(
        _ trees: SnapshotTrees, chaining existing: String?, branch: FeatureBranch, worktreePath: String
    ) async -> Step<String> {
        var parents = ["HEAD"]
        var message = "Yellowhammer snapshot of uncommitted changes in \(branch.name)"
        if let keptIndex = trees.keptIndex {
            let indexMessage = "Yellowhammer snapshot of the staged changes in \(branch.name)"
            switch await commitTree(keptIndex, parents: ["HEAD"], message: indexMessage, worktreePath: worktreePath) {
            case .failure(let reason): return .failure(reason)
            case .success(let indexCommit): parents.append(indexCommit)
            }
            message += "\n\n\(Self.indexTreeTrailer) \(keptIndex)"
        }
        if let existing { parents.append(existing) }
        return await commitTree(trees.work, parents: parents, message: message, worktreePath: worktreePath)
    }

    /// The trailer naming the staged tree a snapshot kept as an index commit; how a later firing tells whether the
    /// same index was already saved.
    static let indexTreeTrailer = "Yellowhammer-Index-Tree:"

    /// HEAD's tree, the working tree as `add -A` sees it, and the staged tree when it differs from both.
    private struct SnapshotTrees {
        let head: String
        let work: String
        let keptIndex: String?
    }

    private enum Step<Value> {
        case success(Value)
        case failure(String)
    }

    /// `git status --porcelain` lines; ignored files never appear. `--no-optional-locks` keeps status from
    /// rewriting the Worktree's index.
    private func status(worktreePath: String) async -> Step<[String]> {
        let result = await git.run([
            "--no-optional-locks", "-C", worktreePath, "status", "--porcelain", "--untracked-files=all"
        ])
        guard result.isSuccess else {
            return .failure(result.failureReason(fallback: "git status exited \(result.exitCode)"))
        }
        return .success(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Builds the trees in a temporary index seeded from a copy of the Worktree's own index, which is never written.
    private func buildTrees(worktreePath: String) async -> Step<SnapshotTrees> {
        guard let head = await resolve(["HEAD^{tree}"], worktreePath: worktreePath) else {
            return .failure("HEAD of \(worktreePath) does not resolve")
        }
        let located = await git.run(["-C", worktreePath, "rev-parse", "--path-format=absolute", "--git-path", "index"])
        let realIndex = located.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard located.isSuccess, !realIndex.isEmpty else {
            return .failure(located.failureReason(fallback: "the Worktree's index could not be located"))
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexPath = directory.appending(component: "index").path(percentEncoded: false)
        let indexed = GitRunner(
            executablePath: git.executablePath,
            environment: git.environment.merging(["GIT_INDEX_FILE": indexPath]) { $1 }
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: realIndex) {
                // The copy must keep the index file's mtime (`copyItem` does). A copy with a fresh mtime makes git's
                // racy-index check trust stale stat data, so a same-size edit in the same second would be missed.
                try FileManager.default.copyItem(atPath: realIndex, toPath: indexPath)
            } else if case .failure(let reason) = await run(["read-tree", "HEAD"], indexed, worktreePath) {
                return .failure(reason)
            }
        } catch {
            return .failure("could not copy the Worktree's index: \(error.localizedDescription)")
        }
        let staged: String
        switch await run(["write-tree"], indexed, worktreePath) {
        case .failure(let reason): return .failure(reason)
        case .success(let tree): staged = tree
        }
        if case .failure(let reason) = await run(["add", "-A"], indexed, worktreePath) { return .failure(reason) }
        switch await run(["write-tree"], indexed, worktreePath) {
        case .failure(let reason): return .failure(reason)
        case .success(let work):
            let keptIndex = staged != head && staged != work ? staged : nil
            return .success(SnapshotTrees(head: head, work: work, keptIndex: keptIndex))
        }
    }

    /// Whether `existing` already saves exactly `trees`: the same working tree and the same kept index, if any.
    private func isSame(_ existing: String, as trees: SnapshotTrees, worktreePath: String) async -> Bool {
        guard await resolve(["\(existing)^{tree}"], worktreePath: worktreePath) == trees.work else { return false }
        let body = await git.run(["-C", worktreePath, "log", "-1", "--format=%B", existing])
        let kept = body.stdout.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix(Self.indexTreeTrailer) }
            .map { $0.dropFirst(Self.indexTreeTrailer.count).trimmingCharacters(in: .whitespaces) }
        return body.isSuccess && kept == trees.keptIndex
    }

    private func commitTree(
        _ tree: String, parents: [String], message: String, worktreePath: String
    ) async -> Step<String> {
        let arguments = [
            "-C", worktreePath,
            "-c", "user.name=\(WIPCommitMessage.authorName)", "-c", "user.email=\(WIPCommitMessage.authorEmail)",
            "-c", "commit.gpgsign=false", "commit-tree", tree
        ] + parents.flatMap { ["-p", $0] } + ["-m", message]
        let committed = await git.run(arguments)
        let commit = committed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard committed.isSuccess, !commit.isEmpty else {
            return .failure(committed.failureReason(fallback: "git commit-tree exited \(committed.exitCode)"))
        }
        return .success(commit)
    }

    /// Runs git with `runner` in the Worktree; the trimmed stdout on success.
    private func run(_ arguments: [String], _ runner: GitRunner, _ worktreePath: String) async -> Step<String> {
        let result = await runner.run(["-C", worktreePath] + arguments)
        guard result.isSuccess else {
            return .failure(result.failureReason(fallback: "git \(arguments[0]) exited \(result.exitCode)"))
        }
        return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolve(_ arguments: [String], worktreePath: String) async -> String? {
        let result = await git.run(["-C", worktreePath, "rev-parse", "--verify", "--quiet"] + arguments)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isSuccess && !value.isEmpty ? value : nil
    }
}
