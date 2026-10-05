import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// graph-execution/allocate-a-worktree-per-graph-and-repo: one Worktree per (Feature, repository),
// reused for later Cards in the same Repo Lane, released only after the Feature Branch is pushed.
// Orca ADE (vendor) owns Worktrees; this suite never imports its adapter, only the Workspace Port.

/// Records every call and creates a real directory per Worktree under `baseDirectory`, so a test can
/// assert on the filesystem as well as on the returned records. Returns `branch == name` unless a
/// collision or failure was scripted for that repository or name.
private final class FakeWorkspace: Workspace, Sendable {
    struct CreateCall: Equatable {
        let repositoryPath: String
        let name: String
        let baseBranch: String?
    }

    struct RemoveCall: Equatable {
        let id: WorktreeID
        let force: Bool
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var removeCalls: [RemoveCall] = []
        var collisionBranches: [String: String] = [:]
        var createFailures: [String: WorkspaceError] = [:]
        var nextID = 0
    }

    let baseDirectory: URL
    private let state = Mutex(State())

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var createCalls: [CreateCall] {
        state.withLock { $0.createCalls }
    }

    var removeCalls: [RemoveCall] {
        state.withLock { $0.removeCalls }
    }

    func scriptCollision(forName name: String, returning branch: String) {
        state.withLock { $0.collisionBranches[name] = branch }
    }

    func scriptFailure(forRepositoryPath path: String, error: WorkspaceError) {
        state.withLock { $0.createFailures[path] = error }
    }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        if let failure = state.withLock({ $0.createFailures[repositoryPath] }) {
            throw failure
        }
        let call = CreateCall(repositoryPath: repositoryPath, name: name, baseBranch: baseBranch)
        state.withLock { $0.createCalls.append(call) }
        let branch = state.withLock { $0.collisionBranches[name] } ?? name
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        let directory = baseDirectory.appendingPathComponent(branch)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: "fake-\(id)"), path: directory.path, branch: branch, displayName: name
        )
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] {
        []
    }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.removeCalls.append(RemoveCall(id: id, force: force)) }
    }
}

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func insertFixtureFeature(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", epoch.formatted(.iso8601)]
        )
        return db.lastInsertedRowID
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID, now: Date = epoch) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

/// Initializes a git repository at `directory` with one commit, returning the commit's SHA.
@discardableResult
private func initGitRepo(at directory: URL, git: GitRunner) async throws -> String {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = await git.run(["init", "--initial-branch=main"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.name", "Test"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.email", "test@example.com"], workingDirectory: directory.path)
    _ = await git.run(["config", "commit.gpgsign", "false"], workingDirectory: directory.path)
    try "content".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = await git.run(["add", "."], workingDirectory: directory.path)
    _ = await git.run(["commit", "-m", "initial"], workingDirectory: directory.path)
    return await git.run(["rev-parse", "HEAD"], workingDirectory: directory.path)
        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("WorktreeAllocator")
struct WorktreeAllocatorTests {
    private static let projectID = ProjectID(rawValue: "proj")!
    private static let featureName = FeatureName(rawValue: "feat")!
    private static let branch = WorktreeName(projectID: projectID, feature: featureName)

    private static func fixtureRepos() -> [Repo] {
        [
            Repo(name: "backend", path: "/tmp/yh-allocator-fixture/backend", role: .backend),
            Repo(name: "mobile", path: "/tmp/yh-allocator-fixture/mobile", role: .mobile),
            Repo(name: "spec", path: "/tmp/yh-allocator-fixture/spec", role: .spec)
        ]
    }

    @Test("Three fixture repos each get one held Worktree, and the workspace is asked for the Feature Branch's name")
    func allocatesOneWorktreePerRepository() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)

        let repos = Self.fixtureRepos()
        let result = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: repos)

        #expect(result.count == 3)
        #expect(result.repositories == ["backend", "mobile", "spec"])
        #expect(workspace.createCalls.count == 3)
        #expect(workspace.createCalls.allSatisfy { $0.name == Self.branch.rawValue })

        for repo in repos {
            let record = try #require(result[repo.name])
            #expect(record.repository == repo.name)
            #expect(record.isHeld)
            let held = try journal.heldWorktree(featureID: featureID, repository: repo.name)
            #expect(held?.id == record.id)
            #expect(held?.path == record.path)
        }
    }

    @Test("A second allocation for the same Feature reuses every held Worktree and makes no create call")
    func secondAllocationReuses() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)

        let repos = Self.fixtureRepos()
        let first = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: repos)
        #expect(workspace.createCalls.count == 3)

        let second = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: repos)

        #expect(workspace.createCalls.count == 3, "the second allocation must not call create again")
        for repo in repos {
            #expect(second[repo.name]?.id == first[repo.name]?.id)
        }
    }

    @Test("A Card resolves its Worktree by repository label")
    func resolvesByRepositoryLabel() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)

        let result = try await allocator.allocate(
            featureID: featureID, worktreeName: Self.branch, repos: Self.fixtureRepos()
        )

        #expect(result["backend"]?.repository == "backend")
        #expect(result["nonexistent"] == nil)
    }

    @Test("git worktree prune runs before allocation and clears a worktree whose directory was deleted by hand")
    func pruneRunsBeforeAllocation() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let repoDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repoDirectory) }
        let git = GitRunner()
        try await initGitRepo(at: repoDirectory, git: git)

        let stray = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-stray-\(UUID().uuidString)", directoryHint: .isDirectory)
        _ = await git.run(
            ["worktree", "add", "-b", "stray-branch", stray.path], workingDirectory: repoDirectory.path
        )
        try FileManager.default.removeItem(at: stray)
        let beforePrune = await git.run(["worktree", "list", "--porcelain"], workingDirectory: repoDirectory.path)
        #expect(beforePrune.stdout.contains(stray.path))

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)

        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)
        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])

        let afterPrune = await git.run(["worktree", "list", "--porcelain"], workingDirectory: repoDirectory.path)
        #expect(!afterPrune.stdout.contains(stray.path))
    }

    @Test("A name collision removes the Worktree Orca ADE made and records nothing in the Journal")
    func nameCollisionThrowsAndCleansUp() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let collided = "\(Self.branch.rawValue)-2"
        workspace.scriptCollision(forName: Self.branch.rawValue, returning: collided)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)

        let repo = Repo(name: "backend", path: "/tmp/yh-allocator-fixture/backend", role: .backend)

        await #expect(throws: WorktreeAllocationError.nameCollision(
            repository: "backend", requested: Self.branch.rawValue, reported: collided, recorded: nil
        )) {
            _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])
        }

        #expect(workspace.removeCalls.count == 1)
        #expect(workspace.removeCalls[0].force)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }

    @Test("Releasing before any push throws notPushed, and the workspace saw no remove call")
    func releaseBeforePushThrows() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        let repo = Repo(name: "backend", path: "/tmp/yh-allocator-fixture/backend", role: .backend)
        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])

        await #expect(throws: WorktreeAllocationError.notPushed(repository: "backend")) {
            try await allocator.release(featureID: featureID, repository: "backend")
        }
        #expect(workspace.removeCalls.isEmpty)
    }

    @Test("discardingUnpushedWork releases an unpushed Worktree instead of refusing (settle *released*, P10.9)")
    func discardingUnpushedWorkReleasesWithoutAPush() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        let repo = Repo(name: "backend", path: "/tmp/yh-allocator-fixture/backend", role: .backend)
        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])

        let record = try await allocator.release(
            featureID: featureID, repository: "backend", discardingUnpushedWork: true
        )

        #expect(record.releasedAt != nil)
        #expect(workspace.removeCalls.count == 1)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }

    @Test("After recordWorktreePush, release removes through the workspace and the Journal record releases")
    func releaseAfterPushSucceeds() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        let repo = Repo(name: "backend", path: "/tmp/yh-allocator-fixture/backend", role: .backend)
        let allocated = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])
        let record = try #require(allocated["backend"])

        _ = try journal.recordWorktreePush(id: record.id, commit: "deadbeef", runID: runID)
        let released = try await allocator.release(featureID: featureID, repository: "backend")

        #expect(!released.isHeld)
        #expect(workspace.removeCalls.count == 1)
        #expect(workspace.removeCalls[0].id.rawValue == record.worktreeID)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }

    @Test("A repositoryNotRegistered failure from the workspace surfaces wrapped as .workspace")
    func repositoryNotRegisteredSurfacesWrapped() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = FakeWorkspace(baseDirectory: workspaceDirectory)
        let repoPath = "/tmp/yh-allocator-fixture/unregistered"
        workspace.scriptFailure(
            forRepositoryPath: repoPath, error: .repositoryNotRegistered(path: repoPath)
        )
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        let repo = Repo(name: "backend", path: repoPath, role: .backend)

        await #expect(throws: WorktreeAllocationError.workspace(
            repository: "backend", .repositoryNotRegistered(path: repoPath)
        )) {
            _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])
        }
    }
}

// The last-known-good-commit test lives in WorktreeAllocatorLastKnownGoodTests.swift, split out to
// keep this file under the length limit.

@Suite("WorktreeAllocator acceptance rule")
struct WorktreeAllocatorAcceptanceTests {
    private static let name = WorktreeName(rawValue: "yh-x")

    private func accepts(_ reported: String, recorded: String? = nil) -> Bool {
        WorktreeAllocator.accepts(
            reported: reported, worktreeName: Self.name, recorded: recorded.map { FeatureBranch(name: $0) }
        )
    }

    @Test("with nothing recorded, the name or a '<prefix>/' before it is accepted")
    func firstAllocation() {
        #expect(accepts("yh-x"))
        #expect(accepts("rozd/yh-x"))
        #expect(accepts("team/rozd/yh-x"))
        #expect(!accepts("yh-x-2"))
        #expect(!accepts("rozd-yh-x"))
    }

    @Test("with a branch recorded, only that exact branch is accepted")
    func recordedBranch() {
        #expect(!accepts("other/yh-x", recorded: "rozd/yh-x"))
        #expect(accepts("rozd/yh-x", recorded: "rozd/yh-x"))
    }
}
