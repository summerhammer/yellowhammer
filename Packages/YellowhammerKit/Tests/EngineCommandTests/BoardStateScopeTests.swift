import Domain
import Testing

@testable import Engine

// board-projection/provision-the-board (P22.8): the board state scope resolves a workflow state id for every
// writable Card state. Waiting on You and Blocked are Yellowhammer's two custom `started` states, found by a
// Board Mapping entry or a persisted id and never by name; Todo, In Progress and Done are the team's native
// `unstarted`, `started` and `completed` states, selected by category (an explicit mapping, else the lowest
// position, a tie broken by id). Shelved is refused outright (glossary → Shelved: read, never written).

private let scopeTeam = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")

private func board(withTeams teams: [BoardTeam] = [scopeTeam]) -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: teams)
    return FakeProvisioningBoard(project: scope)
}

/// A footprint store that holds the ids a provisioning run recorded for the two custom states.
private func persisted(waiting: BoardObjectID, blocked: BoardObjectID) -> InMemoryBoardFootprintStore {
    InMemoryBoardFootprintStore(records: [
        BoardFootprintRecord(team: scopeTeam.id, role: .waitingOnYou, objectID: waiting, source: .provisioned),
        BoardFootprintRecord(team: scopeTeam.id, role: .blocked, objectID: blocked, source: .provisioned)
    ])
}

/// A fully provisioned board: both custom states, every native category, and the disposition labels.
private struct ProvisionedBoard {
    let board: FakeProvisioningBoard
    let waiting: BoardObjectID
    let blocked: BoardObjectID
}

private func provisionedBoard() async throws -> ProvisionedBoard {
    let provisioning = board()
    try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
    await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
    await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
    await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
    await provisioning.seed(state: "Canceled", team: scopeTeam.id, category: .shelved)
    let waiting = await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .started)
    let blocked = await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .started)
    return ProvisionedBoard(board: provisioning, waiting: waiting, blocked: blocked)
}

@Suite("Board state scope")
struct BoardStateScopeTests {
    @Test("Every writable state resolves, and the custom ones are the persisted ids")
    func resolvesEveryWritableState() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting, blocked) = (fixture.board, fixture.waiting, fixture.blocked)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.team == scopeTeam.id)
        #expect(scope.states[.waitingOnYou] == waiting)
        #expect(scope.states[.blocked] == blocked)
        for state: CardState in [.todo, .inProgress, .done, .blocked, .waitingOnYou] {
            #expect(scope.states[state] != nil)
        }
        #expect(scope.canceledState != nil)
    }

    @Test("A same-name state with no persisted id and no mapping is never adopted by name")
    func customStatesAreNeverAdoptedByName() async throws {
        let provisioning = try await provisionedBoard().board

        await #expect(throws: BoardStateScopeError.stateNotProvisioned(name: "Waiting on You", team: scopeTeam.id)) {
            try await BoardStateScope.resolve(using: provisioning, footprint: InMemoryBoardFootprintStore())
        }
    }

    @Test("A Board Mapping entry selects a custom state whatever it is called")
    func mappingSelectsACustomState() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, blocked) = (fixture.board, fixture.blocked)
        let mine = await provisioning.seed(state: "Needs You", team: scopeTeam.id, category: .started)
        let mapping = BoardMapping(ids: [.waitingOnYou: mine])

        let scope = try await BoardStateScope.resolve(
            using: provisioning, mapping: mapping, footprint: persisted(waiting: mine, blocked: blocked)
        )

        #expect(scope.states[.waitingOnYou] == mine)
    }

    @Test("A persisted id whose state is gone, or is no longer started, resolves nothing")
    func aStalePersistedIdIsNotTrusted() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting) = (fixture.board, fixture.waiting)
        let wrongCategory = await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .completed)

        await #expect(throws: BoardStateScopeError.stateNotProvisioned(name: "Blocked", team: scopeTeam.id)) {
            try await BoardStateScope.resolve(
                using: provisioning, footprint: persisted(waiting: waiting, blocked: wrongCategory)
            )
        }
    }

    @Test("A board bound with no footprint store looks the custom states up by name and started category")
    func noStoreFallsBackToName() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting, blocked) = (fixture.board, fixture.waiting, fixture.blocked)

        let scope = try await BoardStateScope.resolve(using: provisioning)

        #expect(scope.states[.waitingOnYou] == waiting)
        #expect(scope.states[.blocked] == blocked)
    }

    @Test("Several completed states select the lowest position; a tie goes to the lowest id")
    func nativeSelectionIsDeterministic() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting, blocked) = (fixture.board, fixture.waiting, fixture.blocked)
        let late = await provisioning.seed(state: "Archived", team: scopeTeam.id, category: .completed, position: 9)
        let tieB = await provisioning.seed(
            state: "Released B", team: scopeTeam.id, category: .completed, position: 0.5, id: "z-state"
        )
        let tieA = await provisioning.seed(
            state: "Released A", team: scopeTeam.id, category: .completed, position: 0.5, id: "a-state"
        )
        _ = (late, tieB)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.states[.done] == tieA)
    }

    @Test("An explicit mapping wins over position")
    func mappingOverridesPosition() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting, blocked) = (fixture.board, fixture.waiting, fixture.blocked)
        let chosen = await provisioning.seed(state: "Shipped", team: scopeTeam.id, category: .completed, position: 50)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, mapping: BoardMapping(ids: [.completed: chosen]),
            footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.states[.done] == chosen)
    }

    @Test("A renamed native state is selected by its category, never by its name")
    func renamedNativeStateIsSelectedByCategory() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Backlog", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Flight", team: scopeTeam.id, category: .started)
        let shipped = await provisioning.seed(state: "Shipped", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Dropped", team: scopeTeam.id, category: .shelved)
        let waiting = await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .started)
        let blocked = await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .started)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.states[.done] == shipped)
        #expect(scope.states[.todo] != nil)
        #expect(scope.states[.inProgress] != nil)
    }

    @Test("The custom states and the legacy settle states are excluded from generic started selection")
    func customAndLegacyStatesAreNotGenericStarted() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        let waiting = await provisioning.seed(
            state: "Waiting on You", team: scopeTeam.id, category: .started, position: 0
        )
        let blocked = await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .started, position: 1)
        for name in FeatureDisposition.legacySettleStateNames {
            await provisioning.seed(state: name, team: scopeTeam.id, category: .started, position: 2)
        }
        // Every `started` state at a lower position than the real one is Yellowhammer's or a legacy one.
        let native = await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started, position: 3)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.states[.inProgress] == native)
    }

    @Test("Without a native started state the team is refused, never filled from a custom one")
    func noNativeStartedRefuses() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        let waiting = await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .started)
        let blocked = await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .started)

        await #expect(throws: BoardStateScopeError.stateNotProvisioned(name: "In Progress", team: scopeTeam.id)) {
            try await BoardStateScope.resolve(
                using: provisioning, footprint: persisted(waiting: waiting, blocked: blocked)
            )
        }
    }

    @Test("Shelved is refused")
    func shelvedIsRefused() async throws {
        let provisioning = try await provisionedBoard().board
        let scope = try await BoardStateScope.resolve(using: provisioning)

        #expect(throws: BoardStateScopeError.shelvedIsNeverWritten) {
            try scope.id(for: .shelved)
        }
    }

    @Test("Feature contention change moves to contention state and strips legacy block reason labels")
    func featureContentionChangeSetsStateAndLabels() async throws {
        let provisioning = board()
        let ids = try await seedDispositionLabels(on: provisioning, team: scopeTeam.id, legacyBlockReason: true)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .started)
        let scope = try await BoardStateScope.resolve(using: provisioning)

        let change = try scope.featureContentionChange()
        #expect(change.workflowState == (try scope.id(for: .todo)))
        #expect(change.addLabels.contains(try #require(ids[CardType.featureCard.rawValue])))
        for reason in BlockReason.allCases {
            #expect(change.removeLabels.contains(try #require(ids[reason.rawValue])))
        }
    }

    @Test("A Card Type label named by a Board Mapping is the one the scope hands out")
    func mappedCardTypeLabelWins() async throws {
        let fixture = try await provisionedBoard()
        let (provisioning, waiting, blocked) = (fixture.board, fixture.waiting, fixture.blocked)
        let mine = await provisioning.seed(label: "Epic", team: scopeTeam.id)

        let scope = try await BoardStateScope.resolve(
            using: provisioning, mapping: BoardMapping(ids: [.featureCard: mine]),
            footprint: persisted(waiting: waiting, blocked: blocked)
        )

        #expect(scope.labels.cardType[.featureCard] == mine)
    }
}
