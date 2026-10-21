import Domain
import Engine
@testable import Journal
import Testing

// board-projection/provision-the-board (P22.8): the persisted footprint ids, the Board Mapping and the
// bootstrap of an already-provisioned board. A matching name alone is never sufficient to adopt a state.

private let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")

private func board() async -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [engineering])
    let board = FakeProvisioningBoard(project: scope)
    await board.seed(state: "Todo", team: engineering.id, category: .unstarted)
    await board.seed(state: "In Progress", team: engineering.id, category: .started)
    await board.seed(state: "Done", team: engineering.id, category: .completed)
    await board.seed(state: "Canceled", team: engineering.id, category: .shelved)
    return board
}

private func run(
    _ board: FakeProvisioningBoard, store: InMemoryBoardFootprintStore = InMemoryBoardFootprintStore(),
    mapping: BoardMapping = .empty, creating: Bool = true
) async throws -> ProvisioningReport {
    let inputs = BoardFootprintInputs(mapping: mapping, store: store)
    let report = creating
        ? try await BoardProvisioner.provision(
            using: board, projectName: "Yellowhammer", createIn: nil, footprint: inputs
        )
        : try await BoardProvisioner.verify(using: board, projectName: "Yellowhammer", footprint: inputs)
    try store.recordFootprint(report.footprint)
    return report
}

private func state(_ name: String) -> (ProvisioningEntry) -> Bool {
    { entry in
        if case .workflowState(name, _) = entry.subject { return true }
        return false
    }
}

private func mapping(_ role: String) -> (ProvisioningEntry) -> Bool {
    { entry in
        if case .boardMapping(role) = entry.subject { return true }
        return false
    }
}

@Suite("Board footprint: persisted ids, mapping and bootstrap")
struct BoardFootprintTests {
    @Test("A first run records every created id as provisioned; a second run records nothing and creates nothing")
    func createdIdsArePersistedAsProvisioned() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()

        let first = try await run(board, store: store)

        let roles = Set(first.footprint.map(\.role))
        #expect(roles == [.waitingOnYou, .blocked, .featureCard, .workCard, .nightCard])
        #expect(first.footprint.allSatisfy { $0.source == .provisioned && $0.team == engineering.id })
        let created = await board.creates
        let second = try await run(board, store: store)
        #expect(second.footprint.isEmpty)
        #expect(!second.isChanged)
        #expect(await board.creates == created)
        #expect(try store.persistedFootprint().count == 5)
    }

    @Test("A persisted id is reused when the state is renamed, and a name alone is not")
    func persistedIdSurvivesARename() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await run(board, store: store)
        let waiting = try #require(try store.persistedFootprint().first { $0.role == .waitingOnYou }).objectID
        await board.rename(state: waiting, to: "Needs Max", team: engineering.id)
        let creates = await board.creates

        let report = try await run(board, store: store, creating: false)

        #expect(report.entries.first(where: state("Waiting on You"))?.outcome == .present)
        #expect(await board.creates == creates)
    }

    @Test("A persisted id whose state was deleted is not recreated under the old name's authority")
    func deletedPersistedStateIsReportedNotAdopted() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await run(board, store: store)
        await board.remove(state: "Blocked", team: engineering.id)

        let verified = try await run(board, store: store, creating: false)

        guard case .missing? = verified.entries.first(where: state("Blocked"))?.outcome else {
            Issue.record("expected Blocked missing")
            return
        }
        #expect(verified.unfinishedSteps.contains { $0.contains("Blocked") })
    }

    // MARK: - Bootstrap on provenance

    @Test("A same-name started state Yellowhammer once wrote to is adopted and recorded as bootstrapped")
    func bootstrapFromDeliveredWrite() async throws {
        let board = await board()
        let mine = await board.seed(state: "Waiting on You", team: engineering.id, category: .started)
        let store = InMemoryBoardFootprintStore(deliveredStateWrites: [mine])

        let first = try await run(board, store: store)

        #expect(first.entries.first(where: state("Waiting on You"))?.outcome == .present)
        let record = try #require(first.footprint.first { $0.role == .waitingOnYou })
        #expect(record.objectID == mine && record.source == .bootstrapped)
        // Blocked had no provenance and no same-name state: it is created, not bootstrapped.
        #expect(first.footprint.first { $0.role == .blocked }?.source == .provisioned)
        let held = try await board.workflowStates(team: engineering.id)
        #expect(held.filter { $0.name == "Waiting on You" }.count == 1)

        let second = try await run(board, store: store)
        #expect(second.footprint.isEmpty)
    }

    @Test("Provenance on a state of another name, or of another category, adopts nothing")
    func provenanceDoesNotCrossNamesOrCategories() async throws {
        let board = await board()
        let wrongCategory = await board.seed(state: "Blocked", team: engineering.id, category: .completed)
        let store = InMemoryBoardFootprintStore(deliveredStateWrites: [wrongCategory])

        let report = try await run(board, store: store)

        #expect(report.entries.first(where: state("Blocked"))?.outcome == .collision("team"))
        #expect(report.footprint.contains { $0.role == .blocked } == false)
    }

    @Test("Without provenance the collision prints the exact Board Mapping lines, and creates nothing")
    func unrelatedSameNameStateCollidesWithMappingLines() async throws {
        let board = await board()
        let unrelated = await board.seed(state: "Blocked", team: engineering.id, category: .started)
        let before = try await board.workflowStates(team: engineering.id).count

        let report = try await run(board)

        let entry = try #require(report.entries.first(where: state("Blocked")))
        #expect(entry.outcome == .collision("team"))
        #expect(entry.mappingHint == "[board.linear.mapping]\nblocked = \"\(unrelated)\"")
        #expect(report.collisionGuideline?.contains("blocked = \"\(unrelated)\"") == true)
        let stateCount = try await board.workflowStates(team: engineering.id).count
        // Only Waiting on You was created; no second Blocked.
        #expect(stateCount == before + 1)
    }

    // MARK: - Board Mapping

    @Test("A mapped state stands in for a custom state whatever its name, and is recorded as mapped")
    func mappingReplacesACustomState() async throws {
        let board = await board()
        let mine = await board.seed(state: "Needs Max", team: engineering.id, category: .started)

        let report = try await run(board, mapping: BoardMapping(ids: [.waitingOnYou: mine]))

        #expect(report.entries.first(where: state("Waiting on You"))?.outcome == .present)
        #expect(report.footprint.first { $0.role == .waitingOnYou } == BoardFootprintRecord(
            team: engineering.id, role: .waitingOnYou, objectID: mine, source: .mapped
        ))
        let held = try await board.workflowStates(team: engineering.id)
        #expect(!held.contains { $0.name == "Waiting on You" })
    }

    @Test("A mapped Card Type label is reused instead of a label being created")
    func mappingReplacesACardTypeLabel() async throws {
        let board = await board()
        let epic = await board.seed(label: "Epic", team: engineering.id)

        let report = try await run(board, mapping: BoardMapping(ids: [.featureCard: epic]))

        let labelEntry = try #require(report.entries.first {
            if case .label("Feature Card", "Card Type", _) = $0.subject { return true }
            return false
        })
        #expect(labelEntry.outcome == .present && labelEntry.id == epic)
        #expect(report.footprint.first { $0.role == .featureCard }?.source == .mapped)
        let names = try await board.labels(team: engineering.id).map(\.name)
        #expect(!names.contains("Feature Card"))
    }

    @Test("A mapped native state replaces the category default")
    func mappingReplacesANativeSelection() async throws {
        let board = await board()
        let shipped = await board.seed(state: "Shipped", team: engineering.id, category: .completed, position: 99)

        let report = try await run(board, mapping: BoardMapping(ids: [.completed: shipped]))

        let entry = try #require(report.entries.first {
            if case .nativeCategory("completed", _) = $0.subject { return true }
            return false
        })
        #expect(entry.outcome == .present && entry.id == shipped)
    }

    @Test("A mapping to a state of the wrong category fails verification, and nothing takes its place")
    func mappingToTheWrongCategory() async throws {
        let board = await board()
        let done = await board.seed(state: "Shipped", team: engineering.id, category: .completed)
        let creates = await board.creates

        let report = try await run(board, mapping: BoardMapping(ids: [.blocked: done]))

        let entry = try #require(report.entries.first(where: mapping("blocked")))
        guard case .invalidMapping(let reason) = entry.outcome else {
            Issue.record("expected invalidMapping, got \(entry.outcome)")
            return
        }
        #expect(reason.contains("completed") && reason.contains("started"))
        #expect(report.hasUnfinishedSteps)
        // No Blocked state was created in its place (nor adopted by name).
        #expect(report.entries.first(where: state("Blocked")) == nil)
        #expect(await board.creates > creates)
        let held = try await board.workflowStates(team: engineering.id)
        #expect(!held.contains { $0.name == "Blocked" })
    }

    @Test("A mapping to an id the team does not hold fails verification")
    func mappingToAMissingId() async throws {
        let board = await board()

        let nowhere = BoardMapping(ids: [
            .completed: BoardObjectID(rawValue: "nowhere"), .nightCard: BoardObjectID(rawValue: "nolabel")
        ])

        let report = try await run(board, mapping: nowhere)

        #expect(report.entries.first(where: mapping("completed")).map { $0.outcome } != nil)
        #expect(report.entries.first(where: mapping("night_card")).map { $0.outcome } != nil)
        #expect(report.unfinishedSteps.contains { $0.contains("Board Mapping `completed`") })
        #expect(report.unfinishedSteps.contains { $0.contains("Board Mapping `night_card`") })
        // Night Card was not created in place of the failed mapping.
        let names = try await board.labels(team: engineering.id).map(\.name)
        #expect(!names.contains("Night Card"))
    }

    @Test("One id serving two meanings fails verification for both")
    func duplicateIdAcrossMeanings() async throws {
        let board = await board()
        let shared = await board.seed(state: "Shared", team: engineering.id, category: .started)

        let report = try await run(
            board, mapping: BoardMapping(ids: [.waitingOnYou: shared, .blocked: shared])
        )

        #expect(report.entries.first(where: mapping("waiting_on_you")) != nil)
        #expect(report.entries.first(where: mapping("blocked")) != nil)
        #expect(report.unfinishedSteps.filter { $0.contains("no id serves two meanings") }.count == 2)
    }

    @Test("A retired mapping alone verifies clean and recreates nothing")
    func retiredMappingChangesNothing() async throws {
        let board = await board()
        let store = InMemoryBoardFootprintStore()
        _ = try await run(board, store: store)
        let creates = await board.creates

        let retired = BoardMapping(retiredKeys: ["abandoned", "block_reason", "kept_in_flight", "override"])

        let report = try await run(board, store: store, mapping: retired)

        #expect(!report.hasUnfinishedSteps && !report.isChanged)
        #expect(await board.creates == creates)
        let names = try await board.workflowStates(team: engineering.id).map(\.name)
        #expect(!names.contains("Kept in Flight") && !names.contains("Abandoned"))
    }

    // MARK: - Native categories

    @Test("A team without a required native category is an actionable incomplete step naming category and team")
    func missingNativeCategory() async throws {
        let board = await board()
        await board.remove(state: "Done", team: engineering.id)
        let creates = await board.creates

        let report = try await run(board)

        let entry = try #require(report.entries.first {
            if case .nativeCategory("completed", _) = $0.subject { return true }
            return false
        })
        guard case .missing(let reason) = entry.outcome else {
            Issue.record("expected missing, got \(entry.outcome)")
            return
        }
        #expect(reason.contains("team ENG") && reason.contains("completed"))
        #expect(report.unfinishedSteps.contains { $0.contains("native workflow category `completed` (team ENG)") })
        // No substitute was created: only the two custom states, the group and its three labels.
        #expect(await board.creates == creates + 6)
        let names = try await board.workflowStates(team: engineering.id).map(\.name)
        #expect(!names.contains("Done"))
    }

    @Test("Custom states and legacy settle states do not satisfy the native started category")
    func customStatesDoNotSatisfyStarted() async throws {
        let board = await board()
        await board.remove(state: "In Progress", team: engineering.id)
        await board.seed(state: "Kept in Flight", team: engineering.id, category: .started)

        let report = try await run(board)

        #expect(report.unfinishedSteps.contains { $0.contains("native workflow category `started` (team ENG)") })
    }
}

@Suite("Delivered state writes are the bootstrap's provenance")
struct DeliveredStateWriteProvenanceTests {
    @Test("A workflow-state write the Outbox delivered is provenance; another state's id is not")
    func deliveredWriteIsProvenance() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let outbox = try outbox(journal, board: board)
        await board.seed(issue: "issue-1", description: nil)
        let delivered = BoardObjectID(rawValue: "state-delivered")

        var change = BoardIssueChange()
        change.workflowState = delivered
        let issue = BoardObjectID(rawValue: "issue-1")
        _ = try await outbox.post(OutboxWrite(
            key: "state-write", write: .updateIssue(issue: issue, change: change, undo: nil)
        ))

        #expect(try journal.hasDeliveredStateWrite(stateID: delivered))
        #expect(try journal.hasDeliveredStateWrite(stateID: BoardObjectID(rawValue: "state-elsewhere")) == false)
    }

    @Test("A footprint id is replaced, not duplicated, when recorded again")
    func footprintRecordsUpsert() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let team = BoardObjectID(rawValue: "team-1")
        let first = BoardFootprintRecord(
            team: team, role: .blocked, objectID: BoardObjectID(rawValue: "a"), source: .bootstrapped
        )
        let replacement = BoardFootprintRecord(
            team: team, role: .blocked, objectID: BoardObjectID(rawValue: "b"), source: .mapped
        )

        try journal.recordBoardFootprint([first])
        try journal.recordBoardFootprint([replacement])

        #expect(try journal.boardFootprint() == [replacement])
    }
}
