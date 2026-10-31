import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

@Suite("Project removal retains Outbox safeguards")
struct ProjectRemovalDeliverySafeguardTests {
    @Test("Removal delivers pending Card-associated writes from an expired run without skipping them")
    func expiredCardWrite() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        let target = await setup.boards.writing.seed(issue: "card", description: nil)
        let cardID = try insertFixtureCard(setup.journal, issueID: target.rawValue)
        await setup.boards.writing.seed(issue: "feature-of-card", description: nil)
        _ = try setup.journal.claimCardLease(cardID: cardID, runID: RunID(),
            now: removalEpoch.addingTimeInterval(-1_000))
        let entry = try setup.outbox.accept(OutboxWrite(key: "card-comment",
            write: .createComment(issue: target, body: "pending Card write"), cardID: cardID))
        try setup.release()
        let output = RecordingOutput()
        #expect(await setup.remove(directory: directory.url, home: home, output: output)
            .run(id: "alpha", yes: true), "\(output.lines)")
        #expect(try setup.journal.outboxEntry(id: entry.id)?.state == .applied)
        #expect(await setup.boards.writing.comments.contains { $0.body == "pending Card write" })
        #expect(try setup.journal.pendingOutboxEntries().isEmpty)
    }

    @Test("An unfenced Night Card fails removal without committing a summary, state or diagnostic")
    func fenceRefusal() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        let issue = BoardObjectID(rawValue: try #require(try setup.journal.currentNight()?.nightCardIssueID))
        await setup.boards.writing.edit(issue, description: "the Operator removed the fence")
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(removalTOMLExists(directory.url))
        #expect(await setup.boards.writing.issue(issue)?.description == "the Operator removed the fence")
        #expect(await setup.boards.writing.issue(issue)?.workflowState == nil)
    }

    @Test("Description budget refusal cannot commit a partial completion")
    func budgetRefusal() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        let budget = try DescriptionBudget(configured: 1, limit: BoardDescriptionLimit(
            maximum: 100_000, unit: .utf16CodeUnits
        ))
        #expect(await setup.remove(directory: directory.url, home: home, budget: budget)
            .run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(removalTOMLExists(directory.url))
        #expect(await setup.boards.writing.liveIssues.first?.workflowState == nil)
    }

    @Test("Lead draft, pending sponsor: lost completion recording retries the same constituent client IDs",
        arguments: ["descriptionRewrite", "issueUpdate"])
    func interruptedSummary(operation: String) async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        let before = try removalJournalContents(setup.journal)
        let clients = Mutex<[UUID]>([])
        #expect(await setup.remove(directory: directory.url, home: home, interrupt: { entry in
            if entry.operation == operation {
                clients.withLock { $0.append(entry.clientID) }
                throw SimulatedCrash()
            }
        }).run(id: "alpha", yes: true) == false)
        #expect(try removalJournalContents(setup.journal) == before)
        #expect(await setup.remove(directory: directory.url, home: home, interrupt: { entry in
            if entry.operation == operation { clients.withLock { $0.append(entry.clientID) } }
        }).run(id: "alpha", yes: true))
        #expect(clients.withLock { $0.count == 2 && $0[0] == $0[1] })
        #expect(await setup.boards.writing.createIssueCalls == 1)
        #expect(try setup.journal.events(ofType: .nightCardCompleted).count == 1)
    }

    @Test("Removal is isolated from a second Project's Journal and board objects")
    func projectIsolation() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
        let setup = try await RemovalDeliverySetup(directory: directory.url)
        _ = try await setup.maintenance.open(night: setup.night)
        try setup.release()
        let otherFixture = try NightCardJournalFixture(project: "beta")
        let other = try otherFixture.open()
        let otherRun = RunID()
        _ = try other.claimActLease(act: .author, runID: otherRun, mode: .real)
        let otherOutbox = Outbox(journal: other, board: setup.boards.writing, runID: otherRun)
        let untouched = await setup.boards.writing.seed(issue: "beta-card", description: fencedDescription)
        _ = try otherOutbox.accept(OutboxWrite(key: "beta-pending", write: .createComment(
            issue: untouched, body: "beta only"
        )))
        let before = try removalJournalContents(other)
        let object = await setup.boards.writing.issue(untouched)
        #expect(await setup.remove(directory: directory.url, home: home).run(id: "alpha", yes: true))
        #expect(try removalJournalContents(other) == before)
        #expect(await setup.boards.writing.issue(untouched) == object)
        #expect(await setup.boards.writing.comments.isEmpty)
    }
}
