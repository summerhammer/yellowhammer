import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Testing

// Naming policy stays above Orca ADE. This stand-in uses the requested name as a real directory
// component and checks out the actual recorded git base, including recovery pins.
private actor NamedDirectoryWorkspace: Workspace {
    let root: URL
    var requestedNames: [String] = []
    let prefix = "team/rozd/"

    init(root: URL) { self.root = root }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID { RegistrationID(rawValue: path) }
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {}
    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        WorkspaceTerminal(handle: TerminalHandle(rawValue: "term-\(worktreeID.rawValue)"), processID: nil)
    }
    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        WorkspaceTerminalState(orphaned: false, processID: nil)
    }
    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {}

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        requestedNames.append(name)
        let id = "named-\(requestedNames.count)"
        let directory = root.appending(component: id).appending(component: name)
        let result = await GitRunner().run([
            "-C", repositoryPath, "worktree", "add", "--detach", directory.path, baseBranch ?? "HEAD"
        ])
        guard result.isSuccess else { throw .refused(code: "git", message: result.stderr) }
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: id), path: directory.path, branch: prefix + name, displayName: name
        )
    }
}

@Suite("Bounded Worktree allocation")
struct WorktreeNameAllocationTests {
    @Test("A stored oversized name allocates in every repository and recovers the same bounded branch")
    func legacyOversizedNameAndRecovery() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .real)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-753")
        let legacy = WorktreeName(rawValue: "yh-carscalm-" + String(repeating: "quota-", count: 60))
        try journal.recordWorktreeName(featureID: featureID, worktreeName: legacy)
        let root = FileManager.default.temporaryDirectory.appending(component: "yh-753-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repos = [
            try await seedBackendRepo(journal, featureID: featureID, under: root),
            try await seedMobileRepo(journal, featureID: featureID, under: root)
        ]
        let workspace = NamedDirectoryWorkspace(root: root.appending(component: "workspaces"))
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        let allocated = try await allocator.allocate(featureID: featureID, worktreeName: legacy, repos: repos)
        let expected = legacy.bounded(featureIssueID: "FEAT-753").rawValue
        #expect(await workspace.requestedNames == [expected, expected])
        #expect(expected.utf8.count <= 200)
        for repo in repos {
            let record = try #require(allocated[repo.name])
            #expect(FileManager.default.fileExists(atPath: record.path))
            let branch = try journal.featureBranch(featureID: featureID, repository: repo.name)
            #expect(branch?.rawValue == "team/rozd/" + expected)
        }

        let held = try #require(allocated["backend"])
        let branch = try #require(try journal.featureBranch(featureID: featureID, repository: "backend"))
        let commit = try #require(held.lastKnownGoodCommit)
        let pin = FeatureBranchRecoveryPin.ref(for: branch)
        let pinned = await GitRunner().run(["-C", repos[0].path, "update-ref", pin, commit])
        #expect(pinned.isSuccess)
        try journal.recordRecoveryCommit(featureID: featureID, repository: "backend", commit: commit, runID: runID)
        try journal.releaseWorktree(id: held.id, runID: runID, discardingUnpushedWork: true)
        let recovered = try await allocator.allocate(featureID: featureID, worktreeName: legacy, repos: [repos[0]])
        #expect(await workspace.requestedNames == [expected, expected, expected])
        #expect(recovered["backend"]?.lastKnownGoodCommit == commit)
        #expect(try journal.recoveryCommit(featureID: featureID, repository: "backend") == nil)
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == branch)
    }

    @Test("An existing recorded legacy branch retains its original request even above the new budget")
    func existingRecordedBranchKeepsName() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .real)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-OLD")
        let legacy = WorktreeName(rawValue: "yh-Project-" + String(repeating: "x", count: 210))
        let branch = FeatureBranch(name: "team/rozd/" + legacy.rawValue)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: branch)
        let root = FileManager.default.temporaryDirectory.appending(component: "yh-753-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await seedBackendRepo(journal, featureID: featureID, under: root)
        let workspace = NamedDirectoryWorkspace(root: root.appending(component: "workspaces"))
        let allocator = WorktreeAllocator(workspace: workspace, journal: journal, runID: runID)
        _ = try await allocator.allocate(featureID: featureID, worktreeName: legacy, repos: [repo])
        #expect(await workspace.requestedNames == [legacy.rawValue])
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == branch)
    }
}
