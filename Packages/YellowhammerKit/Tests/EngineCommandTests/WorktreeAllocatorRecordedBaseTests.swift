import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// graph-execution/allocate-a-worktree-per-graph-and-repo, "Stacked Worktree allocation on effective_base(R)", and
// feature-authoring/select-the-next-feature `#effective-base`: every Worktree of a Feature is cut from the base
// recorded at selection. Orca ADE is only ever the stub Workspace below, which honours `--base-branch` with a real
// `git worktree add --detach`; the real `orca` is never called.

private final class BaseHonouringWorkspace: Workspace, Sendable {
    struct CreateCall: Equatable {
        let name: String
        let baseBranch: String?
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var removeCalls: [WorktreeID] = []
        var nextID = 0
        var ignoresBase = false
    }

    private let state = Mutex(State())
    let baseDirectory: URL
    let git = GitRunner()

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var createCalls: [CreateCall] { state.withLock { $0.createCalls } }
    var removeCalls: [WorktreeID] { state.withLock { $0.removeCalls } }

    /// Makes the stub cut every Worktree from the repository's HEAD, as Orca ADE does with no usable base.
    func ignoreBase() { state.withLock { $0.ignoresBase = true } }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) {}
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        let (id, ignores) = state.withLock { state -> (Int, Bool) in
            state.createCalls.append(CreateCall(name: name, baseBranch: baseBranch))
            state.nextID += 1
            return (state.nextID, state.ignoresBase)
        }
        let directory = baseDirectory.appending(component: "\(name)-\(id)", directoryHint: .isDirectory)
        let result = await git.run([
            "-C", repositoryPath, "worktree", "add", "--detach", directory.path, (ignores ? nil : baseBranch) ?? "HEAD"
        ])
        guard result.isSuccess else { throw .refused(code: "git", message: result.stderr) }
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: "ow-\(id)"), path: directory.path, branch: name, displayName: name
        )
    }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.removeCalls.append(id) }
    }
}

private struct Scene {
    let journal: JournalStore
    let featureID: Int64
    /// A second Feature, the one a stacked record is stacked on.
    let predecessorID: Int64
    let runID: RunID
    let repoDirectory: URL
    let workspace: BaseHonouringWorkspace
    let git = GitRunner()
    let worktreeName: WorktreeName
    /// Commit A (main) and commit B (adds `stacked.txt`).
    let commitA: String
    let commitB: String

    var repo: Repo { Repo(name: "backend", path: repoDirectory.path, role: .backend) }
    var allocator: WorktreeAllocator { WorktreeAllocator(workspace: workspace, journal: journal, runID: runID) }

    init(journal: JournalStore, root: URL) async throws {
        self.journal = journal
        runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: Date()) else {
            throw SceneError.lease
        }
        let created = Date(timeIntervalSince1970: 1_800_000_000).formatted(.iso8601)
        (predecessorID, featureID) = try journal.write { db in
            var ids: [Int64] = []
            for issue in ["F-0", "F-1"] {
                try db.execute(
                    sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, 'selected', ?)",
                    arguments: [issue, created]
                )
                ids.append(db.lastInsertedRowID)
            }
            return (ids[0], ids[1])
        }
        repoDirectory = root.appending(component: "repo", directoryHint: .isDirectory)
        workspace = BaseHonouringWorkspace(baseDirectory: root.appending(component: "wt", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: workspace.baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        worktreeName = WorktreeName(projectID: ProjectID(rawValue: "proj")!, feature: FeatureName(rawValue: "feat")!)

        let path = repoDirectory.path
        for arguments in [
            ["init", "--initial-branch=main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.x"],
            ["config", "commit.gpgsign", "false"]
        ] {
            _ = await git.run(arguments, workingDirectory: path)
        }
        commitA = try await Self.commit("a.txt", in: path, git: git)
        commitB = try await Self.commit("stacked.txt", in: path, git: git)
        // Mainline stays at A, as origin/main does while the stack's tip is only on the landed pin.
        _ = await git.run(["update-ref", "refs/remotes/origin/main", commitA], workingDirectory: path)
        _ = await git.run(["reset", "--hard", commitA], workingDirectory: path)
    }

    private static func commit(_ file: String, in path: String, git: GitRunner) async throws -> String {
        try file.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        _ = await git.run(["add", "."], workingDirectory: path)
        _ = await git.run(["commit", "-m", file], workingDirectory: path)
        return await git.run(["rev-parse", "HEAD"], workingDirectory: path).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func headOfHeldWorktree() async throws -> String {
        let held = try #require(try journal.heldWorktree(featureID: featureID, repository: "backend"))
        let head = await git.run(["-C", held.path, "rev-parse", "HEAD"])
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func record(_ base: FeatureBaseRecord) throws {
        try journal.recordFeatureBases(featureID: featureID, bases: [base])
    }

    func refResolves(_ ref: String) async -> Bool {
        await git.run(["-C", repoDirectory.path, "rev-parse", "--verify", "--quiet", ref]).isSuccess
    }

    enum SceneError: Error { case lease }
}

private struct ScratchRoot: ~Copyable {
    let url = FileManager.default.temporaryDirectory
        .appending(component: "yh-recorded-base-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("WorktreeAllocator recorded base")
struct WorktreeAllocatorRecordedBaseTests {
    private static func journal(_ root: borrowing ScratchRoot) throws -> JournalStore {
        try JournalStore.openSeeded(
            configurationDirectory: root.url.appending(component: "journal"),
            projectID: ProjectID(rawValue: "fixture")!
        )
    }

    @Test("A stacked record cuts from the landed pin and the new Worktree's HEAD is verified against the record")
    func stackedRecordUsesLandedPin() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)
        let landed = ["update-ref", "refs/yellowhammer/landed/team/b1", scene.commitB]
        _ = await scene.git.run(landed, workingDirectory: scene.repoDirectory.path)
        try scene.record(FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/team/b1", baseCommit: scene.commitB,
            stackedOnFeatureID: scene.predecessorID
        ))

        _ = try await scene.allocator.allocate(
            featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
        )

        #expect(scene.workspace.createCalls.map(\.baseBranch) == ["refs/yellowhammer/landed/team/b1"])
        #expect(try await scene.headOfHeldWorktree() == scene.commitB)
    }

    @Test("With the landed pin absent, a stacked record falls back to refs/remotes/origin/<b_last>")
    func stackedRecordFallsBackToRemoteTracking() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)
        _ = await scene.git.run(
            ["update-ref", "refs/remotes/origin/team/b1", scene.commitB], workingDirectory: scene.repoDirectory.path
        )
        try scene.record(FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/team/b1", baseCommit: scene.commitB,
            stackedOnFeatureID: scene.predecessorID
        ))

        _ = try await scene.allocator.allocate(
            featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
        )

        #expect(scene.workspace.createCalls.map(\.baseBranch) == ["refs/remotes/origin/team/b1"])
        #expect(try await scene.headOfHeldWorktree() == scene.commitB)
    }

    @Test("An unstacked record cuts directly at its baseCommit, even after mainline moved on")
    func unstackedRecordCutsAtRecordedCommit() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)
        // The record says mainline was at A at selection; mainline has since moved to B.
        _ = await scene.git.run(
            ["update-ref", "refs/remotes/origin/main", scene.commitB], workingDirectory: scene.repoDirectory.path
        )
        try scene.record(FeatureBaseRecord(
            repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: scene.commitA
        ))

        _ = try await scene.allocator.allocate(
            featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
        )

        #expect(scene.workspace.createCalls.map(\.baseBranch) == [scene.commitA])
        #expect(try await scene.headOfHeldWorktree() == scene.commitA)
    }

    @Test("A HEAD other than baseCommit removes the Worktree, throws recordedBaseMismatch and records nothing")
    func mismatchedHeadThrows() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)
        try scene.record(FeatureBaseRecord(
            repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: scene.commitB
        ))
        scene.workspace.ignoreBase()

        await #expect(throws: WorktreeAllocationError.recordedBaseMismatch(
            repository: "backend", ref: scene.commitB, expected: scene.commitB, found: scene.commitA
        )) {
            _ = try await scene.allocator.allocate(
                featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
            )
        }
        #expect(scene.workspace.removeCalls == [WorktreeID(rawValue: "ow-1")])
        #expect(try scene.journal.heldWorktree(featureID: scene.featureID, repository: "backend") == nil)
    }

    @Test("No feature_base row faults with missingRecordedBase")
    func noRecordFaults() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)

        await #expect(throws: WorktreeAllocationError.missingRecordedBase(repository: "backend")) {
            _ = try await scene.allocator.allocate(
                featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
            )
        }
    }

    @Test("A recovery pin still wins over a stacked record")
    func recoveryPinWins() async throws {
        let root = ScratchRoot()
        let scene = try await Scene(journal: try Self.journal(root), root: root.url)
        let branch = FeatureBranch(name: scene.worktreeName.rawValue)
        try scene.journal.recordFeatureBranch(featureID: scene.featureID, repository: "backend", branch: branch)
        try scene.journal.recordRecoveryCommit(
            featureID: scene.featureID, repository: "backend", commit: scene.commitB, runID: scene.runID
        )
        _ = await scene.git.run(
            ["update-ref", FeatureBranchRecoveryPin.ref(for: branch), scene.commitB],
            workingDirectory: scene.repoDirectory.path
        )
        try scene.record(FeatureBaseRecord(
            repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: scene.commitA
        ))

        _ = try await scene.allocator.allocate(
            featureID: scene.featureID, worktreeName: scene.worktreeName, repos: [scene.repo]
        )

        #expect(scene.workspace.createCalls.map(\.baseBranch) == [FeatureBranchRecoveryPin.ref(for: branch)])
        #expect(try await scene.headOfHeldWorktree() == scene.commitB)
    }
}
