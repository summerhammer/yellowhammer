import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// Split out of WorktreeAllocatorTests.swift to keep that file under the length limit. Covers the
// last-known-good commit ``WorktreeReconciler`` relies on (loop-state/reconcile-worktrees-at-act-start),
// recorded by allocation (object-guide: Worktree.last_known_good_commit, "at allocation").

/// A minimal Workspace stand-in whose `createWorktree` runs a real `git worktree add`, so the
/// resulting Worktree is checked out to a real commit rather than a plain directory.
private final class GitBackedFakeWorkspace: Workspace, Sendable {
    private struct State {
        var nextID = 0
    }

    let baseDirectory: URL
    let git: GitRunner
    private let state = Mutex(State())

    init(baseDirectory: URL, git: GitRunner) {
        self.baseDirectory = baseDirectory
        self.git = git
    }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        let directory = baseDirectory.appendingPathComponent(name)
        _ = await git.run(
            ["-C", repositoryPath, "worktree", "add", "-b", name, directory.path], workingDirectory: repositoryPath
        )
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: "fake-\(id)"), path: directory.path, branch: name, displayName: name
        )
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {}
}

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-lkg-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Suite("WorktreeAllocator, last known-good commit")
struct WorktreeAllocatorLastKnownGoodTests {
    private static let projectID = ProjectID(rawValue: "proj")!
    private static let featureName = FeatureName(rawValue: "feat")!
    private static let branch = WorktreeName(projectID: projectID, feature: featureName)

    @Test("Allocation resolves the Worktree's HEAD and records it as the last known-good commit")
    func allocationRecordsLastKnownGoodCommit() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")

        let repoDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-lkg-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDirectory) }
        let git = GitRunner()
        _ = await git.run(["init", "--initial-branch=main"], workingDirectory: repoDirectory.path)
        _ = await git.run(["config", "user.name", "Test"], workingDirectory: repoDirectory.path)
        _ = await git.run(["config", "user.email", "test@example.com"], workingDirectory: repoDirectory.path)
        _ = await git.run(["config", "commit.gpgsign", "false"], workingDirectory: repoDirectory.path)
        try "content".write(
            to: repoDirectory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8
        )
        _ = await git.run(["add", "."], workingDirectory: repoDirectory.path)
        _ = await git.run(["commit", "-m", "initial"], workingDirectory: repoDirectory.path)
        let baseCommit = await git.run(["rev-parse", "HEAD"], workingDirectory: repoDirectory.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-lkg-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = GitBackedFakeWorkspace(baseDirectory: workspaceDirectory, git: git)
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)

        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)
        let result = try await allocator.allocate(featureID: featureID, worktreeName: Self.branch, repos: [repo])

        let record = try #require(result["backend"])
        #expect(record.lastKnownGoodCommit == baseCommit)
        #expect(!baseCommit.isEmpty)
    }
}
