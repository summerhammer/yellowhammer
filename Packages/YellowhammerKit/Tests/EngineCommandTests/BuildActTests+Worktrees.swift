import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// The build Act's Worktree-reconciliation and Worktree-allocation steps, split out of
// BuildActTests.swift to keep that file under the file length limit.

/// Records every `createWorktree` call and creates a real directory per Worktree under
/// `baseDirectory`, so allocation resolves `branch == name` and succeeds. Modelled on
/// `WorktreeAllocatorTests`' own `FakeWorkspace`, which is file-private there.
private final class BuildActFakeWorkspace: Workspace, Sendable {
    struct RemoveCall: Equatable {
        let id: WorktreeID
        let force: Bool
    }

    private struct State {
        var createCalls: [(repositoryPath: String, name: String)] = []
        var createFailures: Set<String> = []
        var removeCalls: [RemoveCall] = []
        var nextID = 0
    }

    let baseDirectory: URL
    private let state = Mutex(State())

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var createCallCount: Int { state.withLock { $0.createCalls.count } }
    var createCalls: [(repositoryPath: String, name: String)] { state.withLock { $0.createCalls } }
    var removeCalls: [RemoveCall] { state.withLock { $0.removeCalls } }

    /// Every later `createWorktree` for `repositoryPath` throws `.unavailable`.
    func scriptFailure(forRepositoryPath path: String) {
        state.withLock { $0.createFailures.insert(path) }
    }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        if state.withLock({ $0.createFailures.contains(repositoryPath) }) {
            throw WorkspaceError.unavailable("BuildActFakeWorkspace scripted failure for \(repositoryPath)")
        }
        state.withLock { $0.createCalls.append((repositoryPath, name)) }
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        let directory = baseDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: "fake-\(id)"), path: directory.path, branch: name, displayName: name
        )
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.removeCalls.append(RemoveCall(id: id, force: force)) }
    }
}

extension BuildActTests {
    @Test("Worktree reconciliation runs after the lease sweep and before the board repost")
    func worktreeReconciliationRunsBetweenSweepAndRepost() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/nonexistent-wt",
            runID: runID, now: buildActEpoch
        )

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let board = ActBoard(
            reading: FakeReadingBoard([page()]), writing: boards.writing, provisioning: boards.provisioning
        )
        // The reconciler releases the ghost Worktree below, so the backend lane allocates a fresh one
        // before running BACK-1: this fake creates real Worktrees (`ReconcilerFakeWorkspace` never does),
        // and the invocation needs a configured `backend` repository to allocate against.
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/yh-buildact-fixture/backend", role: .backend)
        ])

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        try await invocation.run()

        #expect(workspace.removeCalls == [
            BuildActFakeWorkspace.RemoveCall(id: WorktreeID(rawValue: "wt-1"), force: true)
        ])
        #expect(workspace.createCallCount == 1)

        let events = try journal.events()
        let relevantTypes: Set<JournalEventType> = [.expiredCardLeasesSwept, .worktreeLost, .boardStateReposted]
        let order = events.filter { relevantTypes.contains($0.type) }.map(\.type)
        #expect(order == [.expiredCardLeasesSwept, .worktreeLost, .boardStateReposted])
        #expect(try journal.events(ofType: .actEnded).count == 1)
    }

    @Test("Held Worktrees with no recorded Feature Branch stop the Act")
    func heldWorktreeWithNoBranchStopsTheAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        // No branch recorded.
        _ = try insertReconcilerCycle(journal, featureID: featureID)
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/nonexistent-wt",
            runID: runID, now: buildActEpoch
        )

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            // No Card is in this fixture Cycle, so the trigger needs forcing to reach the Act's work.
            trigger: .forced, runID: runID, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        await #expect(throws: BuildActError.featureBranchUnrecorded(featureID: featureID)) {
            try await invocation.run()
        }
        #expect(try journal.events(ofType: .actIncomplete).count == 1)
    }

    // MARK: - Worktree allocation (graph-execution/allocate-a-worktree-per-graph-and-repo)

    @Test("One build Act allocates one Worktree per repository, named after the Feature Branch")
    func allocatesOneWorktreePerRepository() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo)

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/yh-buildact-fixture/backend", role: .backend),
            Repo(name: "mobile", path: "/tmp/yh-buildact-fixture/mobile", role: .mobile)
        ])

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        #expect(workspace.createCallCount == 2)
        #expect(workspace.createCalls.allSatisfy { $0.name == buildActBranch.name })
        #expect(recorder.seen.map(\.issueID).sorted() == ["BACK-1", "MOB-1"])

        for repository in ["backend", "mobile"] {
            let held = try journal.heldWorktree(featureID: featureID, repository: repository)
            #expect(held != nil)
        }
    }

    @Test("A second build Act reuses the held Worktrees: no second create call")
    func secondBuildActReusesHeldWorktrees() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/yh-buildact-fixture/backend", role: .backend)
        ])

        let firstRunID = RunID()
        guard
            case .claimed = try journal.claimActLease(
                act: .build, runID: firstRunID, mode: .rehearsal, now: buildActEpoch
            )
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let firstInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: firstRunID, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )
        try await firstInvocation.run()
        #expect(workspace.createCallCount == 1)
        let firstHeld = try journal.heldWorktree(featureID: featureID, repository: "backend")

        let secondRunID = RunID()
        guard
            case .claimed = try journal.claimActLease(
                act: .build, runID: secondRunID, mode: .rehearsal, now: buildActEpoch.addingTimeInterval(60)
            )
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let secondInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .forced, runID: secondRunID, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )
        try await secondInvocation.run()

        #expect(workspace.createCallCount == 1, "the second build Act must not call create again")
        let secondHeld = try journal.heldWorktree(featureID: featureID, repository: "backend")
        #expect(secondHeld?.id == firstHeld?.id)
    }

    @Test("A lane with no runnable Cards allocates nothing")
    func laneWithNoRunnableCardsAllocatesNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .waitingOnYou
        )

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/yh-buildact-fixture/backend", role: .backend)
        ])

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .forced, runID: runID, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )
        try await invocation.run()

        #expect(workspace.createCallCount == 0)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }

    @Test("Allocation failing for one repository fails only that lane; the other lane still allocates and runs")
    func allocationFailureFailsOnlyThatLane() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo)

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let mobilePath = "/tmp/yh-buildact-fixture/mobile"
        workspace.scriptFailure(forRepositoryPath: mobilePath)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/yh-buildact-fixture/backend", role: .backend),
            Repo(name: "mobile", path: mobilePath, role: .mobile)
        ])

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, repositories: repositories, workspace: workspace,
            work: BuildAct(cardRunner: recorder).work
        )

        do {
            try await invocation.run()
            Issue.record("expected the Act to throw lanesFailed")
        } catch let BuildActError.lanesFailed(failures) {
            #expect(failures.keys.sorted() == ["mobile"])
        } catch {
            Issue.record("expected BuildActError.lanesFailed, got \(error)")
        }

        #expect(recorder.seen.map(\.issueID) == ["BACK-1"])
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") != nil)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "mobile") == nil)
    }

    @Test("No Workspace bound: nothing is allocated and the fake-runner lane still runs, unchanged")
    func noWorkspaceBoundAllocatesNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .forced, runID: runID, work: BuildAct(cardRunner: recorder).work
        )
        try await invocation.run()

        #expect(recorder.seen.map(\.issueID) == ["BACK-1"])
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }
}
