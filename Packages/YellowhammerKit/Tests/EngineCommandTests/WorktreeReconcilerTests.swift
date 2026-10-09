import Darwin
import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import ProcessTestSupport
import Repositories
import Synchronization
import Testing

// loop-state/reconcile-worktrees-at-act-start: at build Act start, every Worktree this Project's
// in-flight Feature holds is verified against the filesystem alone (never the Workspace Port's list,
// so a sibling Project's Worktree is never touched), fenced quiescent, and either confirmed clean,
// WIP-committed and reset to its last known-good commit, or reported lost. These run against real git
// fixture repositories, mirroring WorktreeAllocatorTests' `git worktree add` recipe.

// MARK: - Shared fixtures (also used by WorktreeReconcilerContinuedTests.swift)

struct ReconcilerJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-reconciler-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

let reconcilerEpoch = Date(timeIntervalSince1970: 1_800_000_000)
let reconcilerProjectID = ProjectID(rawValue: "proj")!
let reconcilerFeatureName = FeatureName(rawValue: "feat")!
let reconcilerBranch = FeatureBranch(
    name: WorktreeName(projectID: reconcilerProjectID, feature: reconcilerFeatureName).rawValue
)

/// Records every `removeWorktree` call and counts `worktrees(repositoryPath:)` calls, so a test can
/// assert reconciliation never consults the Workspace Port's list — only the Journal's own records.
final class ReconcilerFakeWorkspace: Workspace, Sendable {
    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) {}
    struct RemoveCall: Equatable {
        let id: WorktreeID
        let force: Bool
    }

    private struct State {
        var removeCalls: [RemoveCall] = []
        var listCalls = 0
    }

    private let state = Mutex(State())

    var removeCalls: [RemoveCall] { state.withLock { $0.removeCalls } }
    var listCalls: Int { state.withLock { $0.listCalls } }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        throw WorkspaceError.unavailable("ReconcilerFakeWorkspace never creates a Worktree")
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] {
        state.withLock { $0.listCalls += 1 }
        return []
    }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.removeCalls.append(RemoveCall(id: id, force: force)) }
    }
}

func claimReconcilerLease(_ journal: JournalStore, runID: RunID, now: Date = reconcilerEpoch) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

func insertReconcilerFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(reconcilerEpoch)]
        )
        return db.lastInsertedRowID
    }
}

func insertReconcilerCycle(_ journal: JournalStore, featureID: Int64) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(reconcilerEpoch)]
        )
        return db.lastInsertedRowID
    }
}

/// Inserts a fixture Card, choosing the next `authored_order` for `cycleID`/`repository` automatically
/// (the schema's uniqueness is per cycle and repository, not global).
@discardableResult
func insertReconcilerCard(
    _ journal: JournalStore, cycleID: Int64, issueID: String, repository: String, state: CardState,
    title: String? = nil
) throws -> Int64 {
    try journal.write { db in
        let nextOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(authored_order), 0) + 1 FROM card WHERE cycle_id = ? AND repository = ?",
            arguments: [cycleID, repository]
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, title, repository, kind, authored_order, state, budget_epoch,
            created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, title, repository, "card", nextOrder, state.rawValue, 0,
                JournalStore.timestamp(reconcilerEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

/// Initializes a git repository at `directory` with one commit, returning the commit's SHA. `branch` is
/// the initial branch: a fixture that records `directory` itself as a held Worktree passes the Feature
/// Branch, because reconciliation refuses a Worktree whose HEAD is on another branch.
@discardableResult
func initReconcilerGitRepo(
    at directory: URL, git: GitRunner = GitRunner(), branch: String = "main"
) async throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = await git.run(["init", "--initial-branch=\(branch)"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.name", "Test"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.email", "test@example.com"], workingDirectory: directory.path)
    _ = await git.run(["config", "commit.gpgsign", "false"], workingDirectory: directory.path)
    try "content".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = await git.run(["add", "."], workingDirectory: directory.path)
    _ = await git.run(["commit", "-m", "initial"], workingDirectory: directory.path)
    return await reconcilerRevParse("HEAD", in: directory, git: git)
}

/// Adds a Worktree the way Orca ADE would: `git worktree add -b <branch> <directory>`.
func addReconcilerWorktree(repo: URL, branch: String, at directory: URL, git: GitRunner) async {
    _ = await git.run(
        ["-C", repo.path, "worktree", "add", "-b", branch, directory.path], workingDirectory: repo.path
    )
}

/// Creates a git repo at `tempDir/<name>-repo` and a Worktree of it, checked out to `branch`, at
/// `tempDir/<name>-wt`. Returns the Worktree directory and the repo's base commit.
func makeReconcilerRepoAndWorktree(
    named name: String, branch: String, in tempDir: URL, git: GitRunner
) async throws -> (worktree: URL, baseCommit: String) {
    let repo = tempDir.appendingPathComponent("\(name)-repo")
    let baseCommit = try await initReconcilerGitRepo(at: repo, git: git)
    let worktree = tempDir.appendingPathComponent("\(name)-wt")
    await addReconcilerWorktree(repo: repo, branch: branch, at: worktree, git: git)
    return (worktree, baseCommit)
}

func reconcilerRevParse(_ ref: String, in directory: URL, git: GitRunner) async -> String {
    await git.run(["rev-parse", ref], workingDirectory: directory.path)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

func reconcilerPorcelainStatus(in directory: URL, git: GitRunner) async -> String {
    await git.run(["status", "--porcelain"], workingDirectory: directory.path).stdout
}

func reconcilerObjectCount(in directory: URL, git: GitRunner) async -> String {
    await git.run(["rev-list", "--count", "--all"], workingDirectory: directory.path)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A fresh, empty temporary directory this test owns; the caller removes it.
func makeReconcilerTempDir(name: String) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
        .appending(component: "yh-reconciler-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
}

/// Launches `/bin/sleep 30` with `currentDirectory` as its cwd, for `ProcessFencer` to find as a holder.
func makeReconcilerSleepProcess(currentDirectory: URL) throws -> SpawnedChild {
    try SpawnedChild.spawn(executable: "/bin/sleep", arguments: ["30"], currentDirectory: currentDirectory)
}

// MARK: - Suite

@Suite("WorktreeReconciler")
struct WorktreeReconcilerTests {

    @Test("Ghost path: a missing Worktree directory is purged, marked lost, and its in-progress Cards return to Todo")
    // The scenario is the length: a full fixture, then every assertion the story names.
    // swiftlint:disable:next function_body_length
    func ghostPathIsPurged() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "ghost")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (backendWorktree, _) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        let backendRepository = tempDir.appendingPathComponent("backend-repo")
        let tipBeforePurge = await reconcilerRevParse(
            "refs/heads/\(reconcilerBranch.name)", in: backendRepository, git: git
        )
        try FileManager.default.removeItem(at: backendWorktree)

        let (mobileWorktree, _) = try await makeReconcilerRepoAndWorktree(
            named: "mobile", branch: reconcilerBranch.name, in: tempDir, git: git
        )

        let backendRecord = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: backendWorktree.path,
            runID: runID,
            featureBranch: reconcilerBranch
        )
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "mobile", worktreeID: "wt-mobile", path: mobileWorktree.path,
            runID: runID,
            featureBranch: reconcilerBranch
        )

        let inProgressBackend = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "CARD-1", repository: "backend", state: .inProgress
        )
        let inProgressMobile = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "CARD-2", repository: "mobile", state: .inProgress
        )
        let todoBackend = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "CARD-3", repository: "backend", state: .todo
        )

        let workspace = ReconcilerFakeWorkspace()
        // This fake never deletes the branch the way Orca ADE does, so the wait for that deletion is tiny.
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git,
            repositories: ProjectRepositories(workingRepos: [
                Repo(name: "backend", path: backendRepository.path, role: .backend)
            ]),
            branchDeletionTimeout: .milliseconds(50), branchDeletionPollInterval: .milliseconds(10)
        )

        let result = try await reconciler.reconcile(feature: try #require(journal.feature(id: featureID)))

        guard case .lost(let lostRecord) = result["backend"] else {
            Issue.record("expected .lost, got \(String(describing: result["backend"]))")
            return
        }
        #expect(lostRecord.id == backendRecord.id)
        #expect(workspace.removeCalls == [
            ReconcilerFakeWorkspace.RemoveCall(id: WorktreeID(rawValue: "wt-backend"), force: true)
        ])
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)

        let reread = try journal.worktrees(featureID: featureID).first { $0.id == backendRecord.id }
        #expect(reread?.isLost == true)
        #expect(reread?.isHeld == false)

        #expect(try journal.events(ofType: .worktreeLost).count == 1)
        #expect(try journal.events(ofType: .cardStateTransitioned).count == 1)

        // The Feature Branch tip was pinned in the main repository, and recorded, before the purge.
        let pinRef = FeatureBranchRecoveryPin.ref(for: reconcilerBranch)
        #expect(pinRef == "refs/yellowhammer/recovery/\(reconcilerBranch.name)")
        #expect(!tipBeforePurge.isEmpty)
        await #expect(reconcilerRevParse(pinRef, in: backendRepository, git: git) == tipBeforePurge)
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == tipBeforePurge)

        #expect(try journal.card(id: inProgressBackend).state == .todo)
        #expect(try journal.card(id: inProgressMobile).state == .inProgress)
        #expect(try journal.card(id: todoBackend).state == .todo)
    }

    @Test("Dirty worktree: uncommitted edits become a WIP commit and the Worktree resets to known-good")
    func dirtyWorktreeBecomesWIPCommit() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "dirty")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: worktree.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit,
            featureBranch: reconcilerBranch
        )

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )

        let result = try await reconciler.reconcile(feature: try #require(journal.feature(id: featureID)))

        guard case .wipCommitted(let record, let wipCommit, let wipRef, let resetTo) = result["backend"] else {
            Issue.record("expected .wipCommitted, got \(String(describing: result["backend"]))")
            return
        }
        #expect(wipRef == "refs/yellowhammer/wip/\(reconcilerBranch.name)")
        #expect(resetTo == baseCommit)
        #expect(record.wipCommit == wipCommit)

        await #expect(reconcilerRevParse("HEAD", in: worktree, git: git) == baseCommit)
        await #expect(reconcilerPorcelainStatus(in: worktree, git: git).isEmpty)
        await #expect(reconcilerRevParse(wipRef, in: worktree, git: git) == wipCommit)

        let show = await git.run(["show", "--stat", wipCommit], workingDirectory: worktree.path)
        #expect(show.stdout.contains("file.txt"))
        #expect(show.stdout.contains("untracked.txt"))

        let events = try journal.events(ofType: .worktreeWIPCommitted)
        #expect(events.count == 1)
        guard case .worktreeWIPCommitted(let eFeatureID, let eRepository, let eWipCommit, let eWipRef, let eResetTo) =
            events[0].event
        else {
            Issue.record("wrong event type")
            return
        }
        #expect(eFeatureID == featureID)
        #expect(eRepository == "backend")
        #expect(eWipCommit == wipCommit)
        #expect(eWipRef == wipRef)
        #expect(eResetTo == resetTo)
    }

    @Test("A sibling Project's worktree is never touched: never stat'd through the Port, never fenced or committed")
    func siblingWorktreeUntouched() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "sibling")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = tempDir.appendingPathComponent("backend-repo")
        let baseCommit = try await initReconcilerGitRepo(at: repo, git: git)

        let ownWorktree = tempDir.appendingPathComponent("own-wt")
        await addReconcilerWorktree(repo: repo, branch: reconcilerBranch.name, at: ownWorktree, git: git)
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-own", path: ownWorktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit,
            featureBranch: reconcilerBranch
        )

        let siblingBranch = "yh-sibling-feat"
        let siblingWorktree = tempDir.appendingPathComponent("sibling-wt")
        await addReconcilerWorktree(repo: repo, branch: siblingBranch, at: siblingWorktree, git: git)
        try "sibling edit".write(
            to: siblingWorktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8
        )
        let siblingStatusBefore = await reconcilerPorcelainStatus(in: siblingWorktree, git: git)
        #expect(!siblingStatusBefore.isEmpty)

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )

        let result = try await reconciler.reconcile(feature: try #require(journal.feature(id: featureID)))

        guard case .clean = result["backend"] else {
            Issue.record("expected .clean, got \(String(describing: result["backend"]))")
            return
        }
        await #expect(reconcilerPorcelainStatus(in: siblingWorktree, git: git) == siblingStatusBefore)
        let siblingWipRef = await git.run(
            ["-C", siblingWorktree.path, "rev-parse", "--verify", "--quiet", "refs/yellowhammer/wip/\(siblingBranch)"],
            workingDirectory: siblingWorktree.path
        )
        #expect(!siblingWipRef.isSuccess)
        #expect(workspace.removeCalls.isEmpty)
        #expect(workspace.listCalls == 0)
    }
}

// "Reconciling a dirty Worktree twice writes no second WIP commit and no second event" lives in
// WorktreeReconcilerContinuedTests.swift, split out to keep this file under the length limit.
