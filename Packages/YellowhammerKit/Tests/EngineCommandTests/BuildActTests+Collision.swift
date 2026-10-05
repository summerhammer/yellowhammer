import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// A Worktree branch-name collision halts the build Act (graph-execution/allocate-a-worktree-per-graph-and-repo,
// OQ123(c)): the Cards stay Todo, no Attempt is spent, no Card Lease, no Block Reason.

extension BuildActTests {
    private static let backendPath = "/tmp/yh-buildact-fixture/backend"
    private static let mobilePath = "/tmp/yh-buildact-fixture/mobile"

    private static func repositories() -> ProjectRepositories {
        ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backendPath, role: .backend),
            Repo(name: "mobile", path: mobilePath, role: .mobile)
        ])
    }

    @Test("A first-allocation collision halts the Act: no lane starts, no Card runs, nothing is spent")
    func firstAllocationCollisionRunsNoCard() async throws {
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
        let backendCard = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let mobileCard = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo
        )

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        // Lanes derive sorted by repository, so mobile is second: backend is already allocated.
        workspace.scriptReportedBranch("somebody/else", forRepositoryPath: Self.mobilePath)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, repositories: Self.repositories(), workspace: workspace,
            work: BuildAct(cardRunner: recorder).work
        )

        await #expect(
            throws: BuildActError.worktreeNameCollision(
                repository: "mobile", requested: buildActBranch.rawValue, reported: "somebody/else"
            )
        ) {
            try await invocation.run()
        }

        #expect(recorder.seen.isEmpty)
        for id in [backendCard, mobileCard] {
            let card = try journal.card(id: id)
            #expect(card.state == .todo)
            #expect(card.blockReason == nil)
            #expect(try journal.attemptHistory(cardID: id).attemptCount == 0)
        }
        #expect(try journal.cardLeases(heldBy: runID).isEmpty)
        #expect(try journal.events(ofType: .repoLaneStarted).isEmpty)
        // The pre-pass already allocated backend; it is kept and reused by the next Act.
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") != nil)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "mobile") == nil)
        #expect(workspace.removeCalls.count == 1)
        #expect(workspace.removeCalls.first?.force == true)
    }

    @Test("A collision against a recorded Feature Branch names the recorded branch as the one expected")
    func recordedBranchCollisionNamesTheRecordedBranch() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let name = buildActBranch.rawValue
        try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: name))
        try journal.recordFeatureBranch(
            featureID: featureID, repository: "backend", branch: FeatureBranch(rawValue: "rozd/\(name)")
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let card = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )

        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        // Orca ADE's prefix was turned off: it now reports the plain name.
        workspace.scriptReportedBranch(name, forRepositoryPath: Self.backendPath)

        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, repositories: Self.repositories(), workspace: workspace,
            work: BuildAct(cardRunner: recorder).work
        )

        await #expect(
            throws: BuildActError.worktreeNameCollision(
                repository: "backend", requested: "rozd/\(name)", reported: name
            )
        ) {
            try await invocation.run()
        }

        #expect(recorder.seen.isEmpty)
        #expect(try journal.card(id: card).state == .todo)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") == nil)
    }

    @Test("The collision notice stays within 200 characters and offers only the safe remedies")
    func collisionNoticeText() {
        let notice = BuildActError.worktreeNameCollision(
            repository: "yellowhammer", requested: "yh-yellowhammer-night-card",
            reported: "rozd/yh-yellowhammer-night-card"
        ).description
        #expect(notice.count <= 200)
        #expect(notice.contains("git branch -m"))
        #expect(!notice.contains("branch -D"))
        #expect(!notice.contains("worktree rm"))
    }
}
