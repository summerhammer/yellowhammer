import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// Issue #325, spec OQ123: the ghost-Worktree purge deletes the Feature Branch unless it is pinned first.
// Orca ADE deletes a removed Worktree's checked-out local branch — asynchronously, and never a ref outside
// `refs/heads/` — and before the land Act that branch is the only copy of the Feature's Done Cards' commits.
// These run against a real git repository and a Workspace fake that behaves like Orca ADE 1.4.220
// (probe 2026-10-05): it creates a branch per Worktree, and on removal prunes the Worktree metadata and
// then force-deletes the branch.

// MARK: - Orca ADE look-alike

/// A Workspace fake with Orca ADE's observable git behaviour: `createWorktree` runs `git worktree add -b
/// <branch> <dir> <base>` with `<base>` the requested `baseBranch` or `main`, `<branch>` the requested name
/// (optionally behind a scripted prefix) and, when that branch already exists, `<branch>-2` — Orca ADE's
/// silent rename on a name collision. `removeWorktree` deletes the directory, runs `git worktree prune`
/// first (git refuses `branch -D` while its metadata still says the branch is checked out), then
/// `git branch -D`.
final class OrcaLikeWorkspace: Workspace, Sendable {
    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) {}
    struct CreateCall: Equatable {
        let name: String
        let baseBranch: String?
    }

    struct RemoveCall: Equatable {
        let id: WorktreeID
        let force: Bool
    }

    private struct Created {
        let repositoryPath: String
        let path: String
        let branch: String
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var removeCalls: [RemoveCall] = []
        var created: [WorktreeID: Created] = [:]
        var branchPrefix: String?
        var nextID = 0
    }

    private let baseDirectory: URL
    private let git: GitRunner
    private let state = Mutex(State())

    init(baseDirectory: URL, git: GitRunner, branchPrefix: String? = nil) {
        self.baseDirectory = baseDirectory
        self.git = git
        state.withLock { $0.branchPrefix = branchPrefix }
    }

    var createCalls: [CreateCall] { state.withLock { $0.createCalls } }
    var removeCalls: [RemoveCall] { state.withLock { $0.removeCalls } }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        let (id, prefix) = state.withLock { state -> (Int, String?) in
            state.createCalls.append(CreateCall(name: name, baseBranch: baseBranch))
            state.nextID += 1
            return (state.nextID, state.branchPrefix)
        }
        var branch = prefix.map { "\($0)/\(name)" } ?? name
        let existing = await git.run([
            "-C", repositoryPath, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"
        ])
        if existing.isSuccess {
            branch += "-2"
        }
        let directory = baseDirectory.appending(component: "ow-\(id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let add = await git.run([
            "-C", repositoryPath, "worktree", "add", "-b", branch, directory.path, baseBranch ?? "main"
        ])
        guard add.isSuccess else {
            throw WorkspaceError.unavailable("git worktree add failed: \(add.stderr)")
        }
        let worktreeID = WorktreeID(rawValue: "ow-\(id)")
        state.withLock {
            $0.created[worktreeID] = Created(repositoryPath: repositoryPath, path: directory.path, branch: branch)
        }
        return WorkspaceWorktree(id: worktreeID, path: directory.path, branch: branch, displayName: name)
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        let created = state.withLock { state -> Created? in
            state.removeCalls.append(RemoveCall(id: id, force: force))
            return state.created[id]
        }
        guard let created else { throw WorkspaceError.worktreeNotFound(id) }
        try? FileManager.default.removeItem(atPath: created.path)
        _ = await git.run(["-C", created.repositoryPath, "worktree", "prune"])
        _ = await git.run(["-C", created.repositoryPath, "branch", "-D", created.branch])
    }
}

// MARK: - Scene

/// One Feature with one Cycle and one `backend` repository: a real git repository with `main`, the
/// Journal, the Act lease and an Orca ADE look-alike. Removes its temporary directory on deinit.
final class GhostScene {
    let journal: JournalStore
    let runID = RunID()
    let git = GitRunner()
    let tempDir: URL
    let repository: URL
    let featureID: Int64
    let cycleID: Int64
    let baseCommit: String
    let workspace: OrcaLikeWorkspace
    let repositories: ProjectRepositories

    static let name = WorktreeName(rawValue: reconcilerBranch.rawValue)

    init(journal: JournalStore, branchPrefix: String? = nil) async throws {
        self.journal = journal
        try claimReconcilerLease(journal, runID: runID)
        featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(featureID: featureID, worktreeName: Self.name)
        cycleID = try insertReconcilerCycle(journal, featureID: featureID)

        tempDir = try makeReconcilerTempDir(name: "ghost-recovery")
        repository = tempDir.appendingPathComponent("backend-repo")
        baseCommit = try await initReconcilerGitRepo(at: repository, git: git)
        workspace = OrcaLikeWorkspace(
            baseDirectory: tempDir.appendingPathComponent("worktrees"), git: git, branchPrefix: branchPrefix
        )
        repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: repository.path, role: .backend)
        ])
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func allocate() async throws -> WorktreeRecord {
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)
        let allocated = try await allocator.allocate(
            featureID: featureID, worktreeName: Self.name, repos: repositories.workingRepos
        )
        return try #require(allocated["backend"])
    }

    func reconcile(repositories: ProjectRepositories?) async throws -> WorktreeReconciliationOutcome {
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git,
            repositories: repositories,
            branchDeletionTimeout: .seconds(5), branchDeletionPollInterval: .milliseconds(20)
        )
        let reconciliation = try await reconciler.reconcile(feature: try #require(try journal.feature(id: featureID)))
        return try #require(reconciliation["backend"])
    }

    func reconcile() async throws -> WorktreeReconciliationOutcome {
        try await reconcile(repositories: repositories)
    }

    /// The Feature Branch recorded for `backend`.
    func recordedBranch() throws -> FeatureBranch {
        try #require(try journal.featureBranch(featureID: featureID, repository: "backend"))
    }

    /// Commits a file in `worktree` the way a Done Card would, returning the new tip.
    @discardableResult
    func commitFile(in worktree: WorktreeRecord) async throws -> String {
        let directory = URL(fileURLWithPath: worktree.path)
        try "done".write(to: directory.appendingPathComponent("done-card.txt"), atomically: true, encoding: .utf8)
        _ = await git.run(["add", "."], workingDirectory: directory.path)
        _ = await git.run(["commit", "-m", "Done Card"], workingDirectory: directory.path)
        return await reconcilerRevParse("HEAD", in: directory, git: git)
    }

    /// Makes the Worktree a ghost: its directory is removed behind Orca ADE's back.
    func removeDirectory(of worktree: WorktreeRecord) throws {
        try FileManager.default.removeItem(atPath: worktree.path)
    }

    /// `ref`'s commit in the main repository, nil when the ref does not exist.
    func tip(of ref: String) async -> String? {
        let result = await git.run(["-C", repository.path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isSuccess && !sha.isEmpty ? sha : nil
    }

    func pinRef(for branch: FeatureBranch) -> String {
        FeatureBranchRecoveryPin.ref(for: branch)
    }

    func recoveryCommit() throws -> String? {
        try journal.recoveryCommit(featureID: featureID, repository: "backend")
    }

    func lostEvents() throws -> [JournalEvent] {
        try journal.events(ofType: .worktreeLost).map(\.event)
    }
}

// MARK: - Suite

/// A ghost Worktree the purge must leave held: its record, Feature Branch and the branch's tip.
struct HeldGhost {
    let record: WorktreeRecord
    let branch: FeatureBranch
    let tip: String
}

@Suite("Ghost Worktree recovery")
struct GhostWorktreeRecoveryTests {
    @Test("A ghost purge keeps the Feature Branch's commits, and the next allocation re-creates it under the same name")
    func ghostPurgeKeepsCommitsAndNextAllocationRecreatesTheBranch() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())

        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        #expect(branch == reconcilerBranch)
        let tip = try await scene.commitFile(in: first)
        #expect(tip != scene.baseCommit)
        try scene.removeDirectory(of: first)

        guard case .lost(let lost) = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        #expect(lost.id == first.id)
        #expect(scene.workspace.removeCalls.map(\.id) == [WorktreeID(rawValue: "ow-1")])
        #expect(scene.workspace.removeCalls.map(\.force) == [true])
        // Orca ADE deleted the branch the way it does on removal; the pin is what keeps the commits.
        #expect(await scene.tip(of: "refs/heads/\(branch.name)") == nil)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == tip)
        #expect(try scene.recoveryCommit() == tip)
        let lostEvents = try scene.lostEvents()
        #expect(lostEvents.count == 1)
        guard case .worktreeLost(_, _, _, _, let pinnedCommit, _, _) = lostEvents[0] else {
            Issue.record("expected a worktreeLost event")
            return
        }
        #expect(pinnedCommit == tip)

        let second = try await scene.allocate()
        #expect(scene.workspace.createCalls.last?.baseBranch == scene.pinRef(for: branch))
        #expect(try scene.recordedBranch() == branch)
        #expect(await scene.tip(of: "refs/heads/\(branch.name)") == tip)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: second.path)
            .appendingPathComponent("done-card.txt").path))
        #expect(second.lastKnownGoodCommit == tip)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == nil)
        #expect(try scene.recoveryCommit() == nil)
        #expect(try scene.journal.heldWorktree(featureID: scene.featureID, repository: "backend")?.id == second.id)
    }

    @Test("A ghost purge with an Orca ADE branch prefix pins and recovers under the prefixed branch name")
    func prefixedBranchIsPinnedAndRecovered() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open(), branchPrefix: "team/rozd")

        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        #expect(branch.name == "team/rozd/\(reconcilerBranch.name)")
        let tip = try await scene.commitFile(in: first)
        try scene.removeDirectory(of: first)

        guard case .lost = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        #expect(scene.pinRef(for: branch) == "refs/yellowhammer/recovery/team/rozd/\(reconcilerBranch.name)")
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == tip)
        #expect(await scene.tip(of: "refs/heads/\(branch.name)") == nil)

        _ = try await scene.allocate()
        #expect(scene.workspace.createCalls.last?.baseBranch == scene.pinRef(for: branch))
        #expect(try scene.recordedBranch() == branch)
        #expect(await scene.tip(of: "refs/heads/\(branch.name)") == tip)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == nil)
        #expect(try scene.recoveryCommit() == nil)
    }

    @Test("If the pin cannot be written because no repository is configured, the purge does not run")
    func noConfiguredRepositoryHoldsTheGhost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        let tip = try await scene.commitFile(in: first)
        let card = try insertReconcilerCard(
            scene.journal, cycleID: scene.cycleID, issueID: "CARD-1", repository: "backend", state: .inProgress
        )
        try scene.removeDirectory(of: first)

        let outcome = try await scene.reconcile(repositories: nil)

        let ghost = HeldGhost(record: first, branch: branch, tip: tip)
        try await expectGhostHeld(scene, ghost: ghost, card: card, outcome: outcome)
    }

    @Test("If the pin cannot be written because the repository is unreadable, the purge does not run")
    func unreadableRepositoryHoldsTheGhost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        let tip = try await scene.commitFile(in: first)
        let card = try insertReconcilerCard(
            scene.journal, cycleID: scene.cycleID, issueID: "CARD-1", repository: "backend", state: .inProgress
        )
        try scene.removeDirectory(of: first)

        let elsewhere = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: scene.tempDir.appendingPathComponent("no-such-repo").path, role: .backend)
        ])
        let outcome = try await scene.reconcile(repositories: elsewhere)

        let ghost = HeldGhost(record: first, branch: branch, tip: tip)
        try await expectGhostHeld(scene, ghost: ghost, card: card, outcome: outcome)
    }

    /// The whole "purge does not run" contract: `.ghostKept` naming the pin ref, nothing removed, nothing lost.
    private func expectGhostHeld(
        _ scene: GhostScene, ghost: HeldGhost, card: Int64,
        outcome: WorktreeReconciliationOutcome
    ) async throws {
        let (first, branch, tip) = (ghost.record, ghost.branch, ghost.tip)
        guard case .ghostKept(_, let reason) = outcome else {
            Issue.record("expected .ghostKept, got \(outcome)")
            return
        }
        #expect(reason.contains(scene.pinRef(for: branch)))
        #expect(reason.contains("kept"))
        #expect(scene.workspace.removeCalls.isEmpty)
        let held = try scene.journal.heldWorktree(featureID: scene.featureID, repository: "backend")
        #expect(held?.id == first.id)
        #expect(held?.isLost == false)
        #expect(try scene.journal.events(ofType: .worktreeReconciliationFailed).count == 1)
        #expect(try scene.lostEvents().isEmpty)
        #expect(try scene.journal.card(id: card).state == .inProgress)
        #expect(try scene.recoveryCommit() == nil)
        #expect(await scene.tip(of: "refs/heads/\(branch.name)") == tip)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == nil)
    }

    @Test("A crash after recording the recovery commit but before pinning it resumes: pin, then purge")
    func crashBeforePinningResumes() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        let tip = try await scene.commitFile(in: first)
        try scene.journal.recordRecoveryCommit(
            featureID: scene.featureID, repository: "backend", commit: tip, runID: scene.runID
        )
        try scene.removeDirectory(of: first)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == nil)

        guard case .lost = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == tip)
        #expect(try scene.recoveryCommit() == tip)
        #expect(scene.workspace.removeCalls.count == 1)
    }

    @Test("A re-created branch whose tip differs keeps the pin, removes the new Worktree and holds nothing")
    func mismatchedRecreatedBranchKeepsThePin() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let first = try await scene.allocate()
        let branch = try scene.recordedBranch()
        let tip = try await scene.commitFile(in: first)
        try scene.removeDirectory(of: first)
        guard case .lost = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        // The pin moved: Orca ADE's re-created branch will be based on a commit other than the recorded one.
        _ = await scene.git.run([
            "-C", scene.repository.path, "update-ref", scene.pinRef(for: branch), scene.baseCommit
        ])

        do {
            _ = try await scene.allocate()
            Issue.record("expected recoveryMismatch")
        } catch let WorktreeAllocationError.recoveryMismatch(repository, reported, expected, found) {
            #expect(repository == "backend")
            #expect(reported == branch.name)
            #expect(expected == tip)
            #expect(found == scene.baseCommit)
        }

        #expect(scene.workspace.removeCalls.map(\.id) == [WorktreeID(rawValue: "ow-1"), WorktreeID(rawValue: "ow-2")])
        #expect(try scene.recoveryCommit() == tip)
        #expect(await scene.tip(of: scene.pinRef(for: branch)) == scene.baseCommit)
        #expect(try scene.journal.heldWorktree(featureID: scene.featureID, repository: "backend") == nil)
    }
}
