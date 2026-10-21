import Domain
import Engine
import Testing

// The two custom `started` workflow states and the legacy settle pair (board-projection/
// provision-the-board, P22.8). Yellowhammer provisions `Waiting on You` and `Blocked` and nothing else:
// `Kept in Flight` and `Abandoned` are neither created, verified nor deleted. Linear's workflow-state
// uniqueness is scoped to (name, type), not name alone (G-6 probe, 2026-09-23), so a same-named state of
// another type is a collision, never reused — and a same-named `started` state is only ever Yellowhammer's
// on a persisted id, a Board Mapping entry or this Project's own provenance.

private let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")

private func board() -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [engineering])
    return FakeProvisioningBoard(project: scope)
}

private func provision(
    _ board: FakeProvisioningBoard, store: InMemoryBoardFootprintStore = InMemoryBoardFootprintStore()
) async throws -> ProvisioningReport {
    let report = try await BoardProvisioner.provision(
        using: board, projectName: "Yellowhammer", createIn: nil, footprint: BoardFootprintInputs(store: store)
    )
    try store.recordFootprint(report.footprint)
    return report
}

private func outcome(of report: ProvisioningReport, _ state: String) -> ProvisioningEntry.Outcome? {
    report.entries.first { entry in
        if case .workflowState(state, _) = entry.subject { return true }
        return false
    }?.outcome
}

private let keptInFlight = LegacyBoardTaxonomy.settleStateNames[0]
private let abandoned = LegacyBoardTaxonomy.settleStateNames[1]
private let waitingOnYou = BoardProvisioner.waitingOnYouState

@Suite("Board provisioning: custom states and the legacy settle pair")
struct BoardProvisionerSettleStateTests {
    @Test("A bare team gets neither Kept in Flight nor Abandoned, and they are not reported")
    func settleStatesAreNotCreated() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(outcome(of: report, keptInFlight) == nil)
        #expect(outcome(of: report, abandoned) == nil)
        let names = try await board.workflowStates(team: engineering.id).map(\.name)
        #expect(Set(names) == [waitingOnYou, BoardProvisioner.blockedState])
    }

    @Test("Legacy settle states already on the board are neither verified nor deleted nor required")
    func legacySettleStatesAreLeftAlone() async throws {
        let board = board()
        // A legacy `Abandoned` of another type would have been a collision before P22.8.
        let legacyKept = await board.seed(state: keptInFlight, team: engineering.id, category: .started)
        let legacyAbandoned = await board.seed(state: abandoned, team: engineering.id, category: .completed)

        let report = try await provision(board)

        #expect(outcome(of: report, keptInFlight) == nil)
        #expect(outcome(of: report, abandoned) == nil)
        let held = try await board.workflowStates(team: engineering.id)
        #expect(held.contains { $0.id == legacyKept } && held.contains { $0.id == legacyAbandoned })
        #expect(report.collisions.isEmpty)
    }

    @Test("Preflight verification passes on the two-state footprint without the settle pair")
    func verifyPassesOnTheTwoStateFootprint() async throws {
        let board = board()
        let team = engineering.id
        await board.seed(state: "Todo", team: team, category: .unstarted)
        await board.seed(state: "In Progress", team: team, category: .started)
        await board.seed(state: "Done", team: team, category: .completed)
        await board.seed(state: "Canceled", team: team, category: .shelved)
        let store = InMemoryBoardFootprintStore()
        _ = try await provision(board, store: store)

        let verified = try await BoardProvisioner.verify(
            using: board, projectName: "Yellowhammer", footprint: BoardFootprintInputs(store: store)
        )

        #expect(!verified.hasUnfinishedSteps)
        #expect(verified.unfinishedSteps.isEmpty)
    }

    @Test("A same-name Waiting on You of another category is a collision")
    func waitingOnYouCollidesWithAnotherType() async throws {
        let board = board()
        await board.seed(state: "Waiting on You", team: engineering.id, category: .unstarted)

        let report = try await provision(board)

        #expect(outcome(of: report, waitingOnYou) == .collision("team"))
        // It is not adoptable by mapping either: only a `started` state can stand in.
        let entry = try #require(report.entries.first { $0.outcome == .collision("team") })
        #expect(entry.mappingHint == nil)
    }

    @Test("An existing same-name state with a nil category is a collision")
    func sameNameStateWithNilCategoryCollides() async throws {
        let board = board()
        await board.seed(state: "Blocked", team: engineering.id, category: nil)

        let report = try await provision(board)

        #expect(outcome(of: report, BoardProvisioner.blockedState) == .collision("team"))
    }

    @Test("A started and a completed Blocked both existing, with no provenance, is a collision naming both")
    func blockedCollidesWhenBothTypesExist() async throws {
        let board = board()
        await board.seed(state: "Blocked", team: engineering.id, category: .started)
        await board.seed(state: "Blocked", team: engineering.id, category: .completed)

        let report = try await provision(board)

        #expect(outcome(of: report, BoardProvisioner.blockedState) == .collision("team"))
        let held = try await board.workflowStates(team: engineering.id)
        #expect(held.filter { $0.name == "Blocked" }.count == 2)
    }
}
