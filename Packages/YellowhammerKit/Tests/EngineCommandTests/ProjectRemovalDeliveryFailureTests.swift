import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

@Suite("Project removal failure atomicity and retry")
struct ProjectRemovalDeliveryFailureTests {
    @Test("Linear failure after an earlier replay succeeds retains every committed Journal value and the TOML",
        arguments: [BoardError.unreachable("offline"), .unreadableResponse("bad response"),
            .rateLimited(retryAfter: nil, budget: nil), .notAuthenticated("revoked")])
    func replayFailureRollsBack(error: BoardError) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        let target = await setup.boards.writing.seed(issue: "unrelated", description: nil)
        _ = try setup.outbox.accept([
            OutboxWrite(key: "earlier", write: .createComment(issue: target, body: "earlier")),
            OutboxWrite(key: "fails", write: .createComment(issue: target, body: "fails"))
        ])
        await setup.boards.writing.script(.refuse(error), for: "fails")
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        let removal = setup.remove(directory: directory.url, home: home)
        #expect(await removal.run(id: "alpha", yes: true) == false)
        #expect(removalTOMLExists(directory.url))
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(await setup.boards.writing.comments.map(\.body) == ["earlier"])
        await setup.boards.writing.clearScript(for: "fails")
        #expect(await removal.run(id: "alpha", yes: true))
        #expect(await setup.boards.writing.comments.map(\.body) == ["earlier", "fails"])
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
    }

    @Test("Linear refusal between removal summary and workflow state rolls back all local evidence",
        arguments: [BoardError.unreachable("offline"), .unreadableResponse("bad response"),
            .rateLimited(retryAfter: nil, budget: nil), .notAuthenticated("revoked")])
    func completionFailureRollsBack(error: BoardError) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        await setup.boards.writing.refuseStateUpdates(with: error)
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(removalTOMLExists(directory.url))
        #expect(await setup.boards.writing.liveIssues.first?.description?.contains("closed: Project removed") == true)
        await setup.boards.writing.refuseStateUpdates(with: nil)
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        #expect(await setup.boards.writing.liveIssues.count == 1)
    }

    @Test("Lost create receipt is retried under the same client ID without duplicating the Night Card")
    func lostCreateReceipt() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        let scope = try await NightCardScope.resolve(using: setup.boards.provisioning)
        _ = try setup.outbox.accept(OutboxWrite(
            key: NightCardMaintenance.createKey(nightStart: setup.night.nightStart),
            write: .createIssue(BoardIssueDraft(team: scope.team, title: "Night", description:
                ManagedBlockFence.initialDescription(rendered: "open"), labels: [scope.nightCardLabel]), parentKey: nil)
        ))
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        let clients = Mutex<[UUID]>([])
        let interrupted = setup.remove(directory: directory.url, home: home, interrupt: { entry in
            clients.withLock { $0.append(entry.clientID) }
            throw SimulatedCrash()
        })
        #expect(await interrupted.run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(await setup.boards.writing.liveIssues.count == 1)
        #expect(await setup.remove(directory: directory.url, home: home, interrupt: { entry in
            clients.withLock { $0.append(entry.clientID) }
        }).run(id: "alpha", yes: true))
        let seen = clients.withLock { $0 }
        #expect(seen.count >= 2)
        #expect(seen[0] == seen[1])
        #expect(await setup.boards.writing.createIssueCalls == 2)
        #expect(await setup.boards.writing.liveIssues.count == 1)
    }

    @Test("Lead draft, pending sponsor: missing Board Connection reports a whole-step skip even with pending entries")
    func missingConnectionSkipsReplay() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(ConfigurationDirectory.githubOnly)
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try setup.outbox.accept(OutboxWrite(key: "pending", write: .createComment(
            issue: BoardObjectID(rawValue: "untouched"), body: "pending"
        )))
        try setup.release()
        let output = RecordingOutput()
        #expect(await setup.remove(directory: directory.url, home: home, output: output).run(id: "alpha", yes: true))
        #expect(try setup.journal.pendingOutboxEntries().count == 1)
        #expect(output.lines.contains { $0.contains("skipped removal board delivery") })
        #expect(await setup.boards.writing.createCommentCalls == 0)
    }

    @Test("A completion failure retains nonempty Night, Feature, Cycle and Worktree records unchanged")
    func lifecycleFailureRollsBack() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let repo = TestGitRepo(name: "removal-lifecycle-rollback")
        await repo.initRepo()
        let commit = try await repo.commit()
        _ = await repo.run(["checkout", "-b", removalBranch.name])
        try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        let seeded = try await seedRemovableProject(setup.journal, mode: .real, repo: repo, pushedCommit: commit)
        await setup.boards.writing.seed(issue: seeded.featureIssueID, description: nil)
        await setup.boards.writing.refuseStateUpdates(with: .unreadableResponse("lost state response"))
        let workspace = RemovalFakeWorkspace()
        let before = try removalJournalContents(setup.journal)
        #expect(await setup.remove(directory: directory.url, home: home, workspace: workspace)
            .run(id: "alpha", yes: true) == false)
        #expect(workspace.removeCalls == [WorktreeID(rawValue: "wt-1")])
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(try setup.journal.heldWorktrees().count == 1)
        #expect(try setup.journal.inFlightFeature()?.feature.id == seeded.featureID)
        #expect(try setup.journal.currentNight()?.id == setup.night.id)
        #expect(removalTOMLExists(directory.url))
    }
}
