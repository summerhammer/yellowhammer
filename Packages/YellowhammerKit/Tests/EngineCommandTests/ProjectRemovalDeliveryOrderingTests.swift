import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("Project removal ordering and receipt recovery")
struct ProjectRemovalDeliveryOrderingTests {
    @Test("Lead draft, pending sponsor: failed Worktree handling prevents step 7 Night Card completion")
    func failedWorktreeStopsCompletion() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        let repo = TestGitRepo(name: "remove-night-worktree")
        await repo.initRepo()
        let commit = try await repo.commit()
        _ = await repo.run(["checkout", "-b", removalBranch.name])
        try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        _ = try await seedRemovableProject(setup.journal, mode: .real, repo: repo, pushedCommit: commit)
        let workspace = RemovalFakeWorkspace()
        workspace.scriptFailNextRemove()
        let before = try removalJournalContents(setup.journal)
        let writes = await setup.boards.writing.writeLog.count
        #expect(await setup.remove(directory: directory.url, home: home, workspace: workspace)
            .run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(await setup.boards.writing.writeLog.count == writes)
        #expect(removalTOMLExists(directory.url))
    }

    @Test("Removal reconciles an interrupted replacement create without creating another Night Card")
    func replacementReceipt() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        let original = try #require(try setup.journal.currentNight()?.nightCardIssueID)
        try await setup.boards.writing.archiveIssue(BoardObjectID(rawValue: original))
        let scope = try await NightCardScope.resolve(using: setup.boards.provisioning)
        let key = NightCardMaintenance.replacementKey(nightStart: setup.night.nightStart, predecessor: original)
        _ = try setup.outbox.accept(OutboxWrite(key: key, write: .createIssue(BoardIssueDraft(
            team: scope.team, title: "replacement", description: fencedDescription, labels: [scope.nightCardLabel]
        ), parentKey: nil)))
        try setup.release()
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        let replacement = try #require(try setup.journal.night(id: setup.night.id)?.nightCardIssueID)
        #expect(replacement != original)
        #expect(try setup.journal.archivedNightCardIssueIDs(nightID: setup.night.id) == [original])
        #expect(await setup.boards.writing.createIssueCalls == 2)
        let completed = await setup.boards.writing.issue(BoardObjectID(rawValue: replacement))
        #expect(completed?.workflowState == scope.completedState)
        #expect(await setup.boards.writing.issue(BoardObjectID(rawValue: original))?.archived == true)
    }

    @Test("Lead draft, pending sponsor: a fresh Journal salts removal completion independently")
    func freshJournalIdentity() async throws {
        let first = try NightCardJournalFixture(project: "alpha")
        let second = try NightCardJournalFixture(project: "alpha")
        let journal = try JournalStore.open(configurationDirectory: first.directory, projectID: first.projectID,
            linearWorkspace: BoardObjectID(rawValue: "workspace-1"))
        let fresh = try JournalStore.open(configurationDirectory: second.directory, projectID: second.projectID,
            linearWorkspace: BoardObjectID(rawValue: "workspace-1"))
        let board = FakeWritingBoard()
        let key = ProjectRemovalBoardDelivery.completionKey(issueID: "same-id")
        let oldOutbox = Outbox(journal: journal, board: board, runID: RunID())
        let newOutbox = Outbox(journal: fresh, board: board, runID: RunID())
        #expect(oldOutbox.clientID(for: key + ":summary") != newOutbox.clientID(for: key + ":summary"))
        #expect(oldOutbox.clientID(for: key + ":complete") != newOutbox.clientID(for: key + ":complete"))
    }

    @Test("Lead draft, pending sponsor: confirmation lists completing the Night Card after the Worktree step")
    func confirmationListsNightCardCompletion() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let output = RecordingOutput()
        let removal = makeRemoval(
            directory: directory, home: home, output: output, console: ScriptedConsole(answers: ["n"])
        )

        #expect(await removal.run(id: "alpha", yes: false) == false)

        let worktreeLine = "- WIP-commit, push and remove each of its held Worktrees"
        let worktrees = try #require(output.lines.firstIndex(of: worktreeLine))
        let nightCard = try #require(output.lines.firstIndex(of: "- complete its open Night Card"))
        let night = try #require(output.lines.firstIndex(of: "- close its open Night, if one exists"))
        #expect(nightCard == worktrees + 1)
        #expect(night == nightCard + 1)
        #expect(removalTOMLExists(directory.url))
    }
}
