import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("Project removal Outbox replay and Night Card completion")
struct ProjectRemovalDeliveryTests {
    @Test("Removal recovers an applied create receipt when the Act died before recording its Night Card")
    func appliedCreateWithoutNightRecord() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        let scope = try await NightCardScope.resolve(using: setup.boards.provisioning)
        let create = try await setup.outbox.post(OutboxWrite(
            key: NightCardMaintenance.createKey(nightStart: setup.night.nightStart),
            write: .createIssue(BoardIssueDraft(team: scope.team, title: "Night", description:
                ManagedBlockFence.initialDescription(rendered: "open"), labels: [scope.nightCardLabel]), parentKey: nil)
        ))
        let issueID = try #require(create.entry.result)
        #expect(create.entry.state == .applied)
        #expect(try setup.journal.currentNight()?.nightCardIssueID == nil)
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
        try setup.release()

        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))

        let night = try #require(try setup.journal.night(id: setup.night.id))
        #expect(night.nightCardIssueID == issueID)
        #expect(night.closeReason == .projectRemoved)
        #expect(await setup.boards.writing.createIssueCalls == 1)
        let completed = await setup.boards.writing.issue(BoardObjectID(rawValue: issueID))
        #expect(completed?.workflowState == scope.completedState)
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
        #expect(!removalTOMLExists(directory.url))
    }

    @Test("Lead draft, pending sponsor: ordered replay reconciles the create and completes a Night without a Feature")
    func replayAndComplete() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        let unrelated = await setup.boards.writing.seed(issue: "unrelated", description: nil)
        let first = try setup.outbox.accept(OutboxWrite(key: "earlier", write: .createComment(
            issue: unrelated, body: "first"
        )))
        let second = try setup.outbox.accept(OutboxWrite(key: "later", write: .createComment(
            issue: unrelated, body: "second"
        )))
        let scope = try await NightCardScope.resolve(using: setup.boards.provisioning)
        let create = try setup.outbox.accept(OutboxWrite(
            key: NightCardMaintenance.createKey(nightStart: setup.night.nightStart),
            write: .createIssue(BoardIssueDraft(team: scope.team, title: "Night", description:
                ManagedBlockFence.initialDescription(rendered: "open"), labels: [scope.nightCardLabel]), parentKey: nil)
        ))
        try setup.release()
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        #expect(await setup.boards.writing.comments.map(\.body) == ["first", "second"])
        #expect(try setup.journal.outboxEntry(id: first.id)?.state == .applied)
        #expect(try setup.journal.outboxEntry(id: second.id)?.state == .applied)
        let createdID = try #require(try setup.journal.outboxEntry(id: create.id)?.result)
        let night = try #require(try setup.journal.night(id: setup.night.id))
        #expect(night.nightCardIssueID == createdID)
        #expect(night.closeReason == .projectRemoved)
        let card = try #require(await setup.boards.writing.issue(BoardObjectID(rawValue: createdID)))
        #expect(card.workflowState == scope.completedState)
        #expect(card.description?.contains("closed: Project removed") == true)
        #expect(card.description?.contains("**Bounds:**") == true)
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
        #expect(!removalTOMLExists(directory.url))
        #expect(FileManager.default.fileExists(atPath: setup.journal.fileURL.path))
        let key = ProjectRemovalBoardDelivery.completionKey(issueID: createdID)
        #expect(try setup.journal.outboxEntry(
            clientID: setup.outbox.clientID(for: key + ":summary"))?.state == .applied)
        #expect(try setup.journal.outboxEntry(
            clientID: setup.outbox.clientID(for: key + ":complete"))?.state == .applied)

        // Same-day re-add resolves by Journal identity alone; there is no board discovery or title matching.
        try directory.writeValidProjectFile(id: "alpha")
        let run = RunID()
        _ = try setup.journal.claimActLease(act: .author, runID: run, mode: .real, now: removalEpoch)
        let reopened = try setup.journal.openNight(nightStart: removalNightStart, mode: .real,
            act: .author, runID: run, now: removalEpoch)
        #expect(reopened.night.id == night.id)
        #expect(!reopened.night.isOpen)
        #expect(reopened.night.closeReason == .projectRemoved)
        #expect(await setup.boards.writing.createIssueCalls == 1)
        #expect(await setup.reading.calls.isEmpty)
    }

    @Test("Removal replays a closed Night's pending night_end completion without an in-flight Feature")
    func closedNightReplay() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        _ = try await setup.maintenance.acceptCompletion(night: setup.night)
        _ = try setup.journal.closeNight(id: setup.night.id, reason: .nightEnd,
            act: .land, runID: setup.runID, now: removalEpoch)
        try setup.release()
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
        #expect(try setup.journal.night(id: setup.night.id)?.closeReason == .nightEnd)
        let card = try #require(await setup.boards.writing.liveIssues.first)
        let scope = try await NightCardScope.resolve(using: setup.boards.provisioning)
        #expect(card.workflowState == scope.completedState)
        #expect(card.description?.contains("closed: Project removed") == false)
    }

    @Test("Lead draft, pending sponsor: no card causes no create and an archived card stays unchanged",
        arguments: [false, true])
    func absentOrArchivedCard(archived: Bool) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        if archived {
            _ = try await setup.maintenance.open(night: setup.night)
            let id = try #require(try setup.journal.currentNight()?.nightCardIssueID)
            try await setup.boards.writing.archiveIssue(BoardObjectID(rawValue: id))
        }
        let before = await setup.boards.writing.archivedIssues
        try setup.release()
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        #expect(await setup.boards.writing.createIssueCalls == (archived ? 1 : 0))
        #expect(await setup.boards.writing.archivedIssues == before)
    }
}
