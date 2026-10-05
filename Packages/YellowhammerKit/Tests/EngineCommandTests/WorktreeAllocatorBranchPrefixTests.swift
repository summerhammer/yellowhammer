import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Synchronization
import Testing

// Orca ADE may report a Feature Branch with a `<prefix>/` before the requested Worktree name. Covers
// what the allocator accepts, records and refuses (object-guide: Worktree, Feature Branch).

/// A Workspace stand-in whose `createWorktree` runs a real `git worktree add -b <reported branch>`,
/// where the reported branch is scripted per call. `removeWorktree` records the call and really
/// removes the git worktree and its branch, so a later allocation can add the same branch again.
private final class PrefixingGitWorkspace: Workspace, Sendable {
    struct RemoveCall: Equatable {
        let id: WorktreeID
        let force: Bool
    }

    private struct Created {
        let repositoryPath: String
        let directory: String
        let branch: String
    }

    private struct State {
        var nextID = 0
        var reportedQueue: [String]
        var removeCalls: [RemoveCall] = []
        var created: [String: Created] = [:]
    }

    let baseDirectory: URL
    let git: GitRunner
    private let state: Mutex<State>

    init(baseDirectory: URL, git: GitRunner, reported: [String]) {
        self.baseDirectory = baseDirectory
        self.git = git
        self.state = Mutex(State(reportedQueue: reported))
    }

    var removeCalls: [RemoveCall] { state.withLock { $0.removeCalls } }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        let (id, branch) = state.withLock { state in
            state.nextID += 1
            let branch = state.reportedQueue.isEmpty ? name : state.reportedQueue.removeFirst()
            return (state.nextID, branch)
        }
        let directory = baseDirectory.appendingPathComponent("wt-\(id)")
        _ = await git.run(
            ["-C", repositoryPath, "worktree", "add", "-b", branch, directory.path], workingDirectory: repositoryPath
        )
        let worktreeID = "fake-\(id)"
        state.withLock {
            $0.created[worktreeID] = Created(repositoryPath: repositoryPath, directory: directory.path, branch: branch)
        }
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: worktreeID), path: directory.path, branch: branch, displayName: name
        )
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        let created = state.withLock { state in
            state.removeCalls.append(RemoveCall(id: id, force: force))
            return state.created[id.rawValue]
        }
        guard let created else { return }
        _ = await git.run(
            ["-C", created.repositoryPath, "worktree", "remove", "--force", created.directory],
            workingDirectory: created.repositoryPath
        )
        _ = await git.run(
            ["-C", created.repositoryPath, "branch", "-D", created.branch], workingDirectory: created.repositoryPath
        )
    }
}

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-allocator-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
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

/// A real git repository with one commit on `main`.
private func makeRepository(git: GitRunner) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-allocator-prefix-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = await git.run(["init", "--initial-branch=main"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.name", "Test"], workingDirectory: directory.path)
    _ = await git.run(["config", "user.email", "test@example.com"], workingDirectory: directory.path)
    _ = await git.run(["config", "commit.gpgsign", "false"], workingDirectory: directory.path)
    try "content".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = await git.run(["add", "."], workingDirectory: directory.path)
    _ = await git.run(["commit", "-m", "initial"], workingDirectory: directory.path)
    return directory
}

private func refExists(_ ref: String, in repository: URL, git: GitRunner) async -> Bool {
    await git.run(["show-ref", "--verify", "--quiet", ref], workingDirectory: repository.path).isSuccess
}

@Suite("WorktreeAllocator, Orca ADE branch prefix")
struct WorktreeAllocatorBranchPrefixTests {
    private static let name = WorktreeName(
        projectID: ProjectID(rawValue: "proj")!, feature: FeatureName(rawValue: "feat")!
    )
    private static let nameString = name.rawValue

    @Test("A Feature Branch reported with a prefix is accepted, recorded as reported, and never renamed")
    func prefixedFeatureBranchIsRecorded() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let git = GitRunner()
        let repoDirectory = try await makeRepository(git: git)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: repoDirectory)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
        let workspace = PrefixingGitWorkspace(
            baseDirectory: workspaceDirectory, git: git, reported: ["rozd/\(Self.nameString)"]
        )
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)
        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)

        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.name, repos: [repo])

        #expect(try journal.featureBranch(featureID: featureID, repository: "backend")?.rawValue
            == "rozd/\(Self.nameString)")
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") != nil)
        #expect(await refExists("refs/heads/rozd/\(Self.nameString)", in: repoDirectory, git: git))
        #expect(await !refExists("refs/heads/\(Self.nameString)", in: repoDirectory, git: git))
        #expect(workspace.removeCalls.isEmpty)
    }

    @Test("A Feature Branch reported with a multi-segment prefix is accepted and recorded as reported")
    func multiSegmentPrefixIsRecorded() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let git = GitRunner()
        let repoDirectory = try await makeRepository(git: git)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: repoDirectory)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
        let workspace = PrefixingGitWorkspace(
            baseDirectory: workspaceDirectory, git: git, reported: ["team/rozd/\(Self.nameString)"]
        )
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)
        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)

        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.name, repos: [repo])

        #expect(try journal.featureBranch(featureID: featureID, repository: "backend")?.rawValue
            == "team/rozd/\(Self.nameString)")
        #expect(workspace.removeCalls.isEmpty)
    }

    @Test("A suffixed Feature Branch is a collision: the Worktree is removed and nothing is recorded")
    func suffixedFeatureBranchCollides() async throws {
        let fixture = try JournalFixture()
        try await expectCollision(reported: "\(Self.nameString)-2", journal: fixture.open())
    }

    @Test("A Feature Branch with the name after a dash, not a slash, is a collision")
    func dashPrefixedFeatureBranchCollides() async throws {
        let fixture = try JournalFixture()
        try await expectCollision(reported: "rozd-\(Self.nameString)", journal: fixture.open())
    }

    @Test("Re-allocation reporting a different prefix is a collision against the recorded Feature Branch")
    func reallocationWithDifferentPrefixCollides() async throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let git = GitRunner()
        let repoDirectory = try await makeRepository(git: git)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: repoDirectory)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
        let workspace = PrefixingGitWorkspace(
            baseDirectory: workspaceDirectory, git: git,
            reported: ["rozd/\(Self.nameString)", "team/\(Self.nameString)"]
        )
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)
        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)

        _ = try await allocator.allocate(featureID: featureID, worktreeName: Self.name, repos: [repo])
        try await allocator.release(featureID: featureID, repository: "backend", discardingUnpushedWork: true)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)

        await #expect(
            throws: WorktreeAllocationError.nameCollision(
                repository: "backend", requested: Self.nameString,
                reported: "team/\(Self.nameString)", recorded: "rozd/\(Self.nameString)"
            )
        ) {
            try await allocator.allocate(featureID: featureID, worktreeName: Self.name, repos: [repo])
        }

        let removes = workspace.removeCalls
        #expect(removes.count == 2)
        #expect(removes.last?.id.rawValue == "fake-2")
        #expect(removes.last?.force == true)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend")?.rawValue
            == "rozd/\(Self.nameString)")
    }

    /// The caller creates the Journal fixture in its own `@Test` body, so the fixture outlives the Journal.
    private func expectCollision(reported: String, journal: JournalStore) async throws {
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFixtureFeature(journal, issueID: "FEAT-1")
        let git = GitRunner()
        let repoDirectory = try await makeRepository(git: git)
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-workspace-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: repoDirectory)
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
        let workspace = PrefixingGitWorkspace(baseDirectory: workspaceDirectory, git: git, reported: [reported])
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID, git: git)
        let repo = Repo(name: "backend", path: repoDirectory.path, role: .backend)

        await #expect(
            throws: WorktreeAllocationError.nameCollision(
                repository: "backend", requested: Self.nameString, reported: reported, recorded: nil
            )
        ) {
            try await allocator.allocate(featureID: featureID, worktreeName: Self.name, repos: [repo])
        }

        let removes = workspace.removeCalls
        #expect(removes.count == 1)
        #expect(removes.first?.force == true)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == nil)
    }
}
