import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P8.11: the build Act's rehearsal boundaries (system-overview, Environment Differences). A
// rehearsal Night never dispatches an agent CLI (no process spawn), never pushes and never opens a
// pull request; it still writes to Linear, allocates real Worktrees, uses the real Ledger, and never
// commits into a Worktree.

/// An `AgentDispatch` that answers from ``RehearsalDispatch`` but reports the conservative default
/// origin (`.agentCLIProcess`) instead of `.rehearsalFixture`, standing in for a real-mode CLI adapter
/// whose report says nothing about its origin.
private struct DefaultOriginDispatch: AgentDispatch {
    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let report = try await RehearsalDispatch().dispatch(request)
        return AgentDispatchReport(outcome: report.outcome, session: report.session)
    }
}

@Suite("Rehearsal boundary: agent CLI process spawns")
struct RehearsalBoundaryDispatchTests {
    @Test("A rehearsal build Act records zero agent CLI process spawns and a fixture-answered event per pass")
    func rehearsalRunRecordsFixtureAnsweredNotProcessSpawned() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal, cards: [("BACK-1", "backend")])
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: RehearsalDispatch(), check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let spawned = try journal.events(ofType: .agentCLIProcessSpawned)
        let answered = try journal.events(ofType: .rehearsalFixtureAnswered)
        #expect(spawned.isEmpty)
        // The default rehearsal script runs architect, worker and reviewer: one fixture answer each.
        #expect(answered.count == 3)

        let events = try journal.events()
        let pushOrPull = events.filter { event in
            let name = String(describing: event.event.type).lowercased()
            return name.contains("push") || name.contains("pull")
        }
        #expect(pushOrPull.isEmpty)
    }

    @Test("A real-mode run whose dispatch reports the default origin records an agent CLI process spawn per pass")
    func realModeRunRecordsProcessSpawnedPerPass() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal, cards: [("BACK-1", "backend")])
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: DefaultOriginDispatch(), check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let spawned = try journal.events(ofType: .agentCLIProcessSpawned)
        let answered = try journal.events(ofType: .rehearsalFixtureAnswered)
        #expect(spawned.count == 3)
        #expect(answered.isEmpty)
    }
}

@Suite("Rehearsal boundary: never commit into a held Worktree")
struct RehearsalBoundaryWorktreeTests {
    @Test("A rehearsal build Act with a dirty held Worktree writes no commit, leaves changes in place")
    func rehearsalBuildActNeverCommitsIntoADirtyWorktree() async throws {
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
            featureID: featureID, worktreeName: WorktreeName(rawValue: reconcilerBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "rehearsal-dirty")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit, now: buildActEpoch
        )

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let board = ActBoard(
            reading: FakeReadingBoard([page()]), writing: boards.writing, provisioning: boards.provisioning
        )
        let workspace = ReconcilerFakeWorkspace()

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        try await invocation.run()

        await #expect(reconcilerRevParse("HEAD", in: worktree, git: git) == baseCommit)
        let status = await reconcilerPorcelainStatus(in: worktree, git: git)
        #expect(status.contains("file.txt"))
        #expect(try journal.events(ofType: .worktreeReconciliationFailed).count == 1)
        #expect(try journal.events(ofType: .worktreeWIPCommitted).isEmpty)
    }

    @Test("A real-mode build Act with the same dirty held Worktree commits it as a WIP commit")
    func realModeBuildActCommitsADirtyWorktree() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: reconcilerBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "real-dirty")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit, now: buildActEpoch
        )

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let board = ActBoard(
            reading: FakeReadingBoard([page()]), writing: boards.writing, provisioning: boards.provisioning
        )
        let workspace = ReconcilerFakeWorkspace()

        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        try await invocation.run()

        await #expect(reconcilerRevParse("HEAD", in: worktree, git: git) == baseCommit)
        await #expect(reconcilerPorcelainStatus(in: worktree, git: git).isEmpty)
        #expect(try journal.events(ofType: .worktreeWIPCommitted).count == 1)
        #expect(try journal.events(ofType: .worktreeReconciliationFailed).isEmpty)
    }
}
