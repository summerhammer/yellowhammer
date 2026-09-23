import Domain
import Engine
import Testing

// The settle workflow-state group (G-6; spec: morning-report/triage-the-morning). Linear's
// workflow-state uniqueness is scoped to (name, type), not name alone (G-6 probe, 2026-09-23), so a
// same-named state of another type is a collision, never reused.

private let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")

private func board() -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [engineering])
    return FakeProvisioningBoard(project: scope)
}

private func provision(_ board: FakeProvisioningBoard) async throws -> ProvisioningReport {
    try await BoardProvisioner.provision(using: board, projectName: "Yellowhammer", createIn: nil)
}

private func outcome(of report: ProvisioningReport, _ state: String) -> ProvisioningEntry.Outcome? {
    report.entries.first { entry in
        if case .workflowState(state, _) = entry.subject { return true }
        return false
    }?.outcome
}

private let keptInFlight = SettleValue.keptInFlight.rawValue
private let released = SettleValue.released.rawValue
private let waitingOnYou = BoardProvisioner.waitingOnYouState

@Suite("Board provisioning: settle workflow states")
struct BoardProvisionerSettleStateTests {
    @Test("A bare team gets Kept in Flight and Released created with category started")
    func settleStatesAreCreatedStarted() async throws {
        let board = board()
        let report = try await provision(board)

        #expect(outcome(of: report, keptInFlight) == .created)
        #expect(outcome(of: report, released) == .created)
        let states = try await board.workflowStates(team: engineering.id)
        let keptInFlightState = try #require(states.first { $0.name == SettleValue.keptInFlight.rawValue })
        let releasedState = try #require(states.first { $0.name == SettleValue.released.rawValue })
        #expect(keptInFlightState.category == .started)
        #expect(releasedState.category == .started)
    }

    @Test("An existing released of category started, lowercase, is present, not created again")
    func releasedMatchesCaseInsensitivelyWhenStarted() async throws {
        let board = board()
        await board.seed(state: "released", team: engineering.id, category: .started)

        let report = try await provision(board)

        #expect(outcome(of: report, released) == .present)
        #expect(outcome(of: report, keptInFlight) == .created)
    }

    @Test("An existing Released of category completed is a collision, nothing named Released is created")
    func releasedOfAnotherTypeCollides() async throws {
        let board = board()
        await board.seed(state: "Released", team: engineering.id, category: .completed)

        let report = try await provision(board)

        #expect(outcome(of: report, released) == .collision("team"))
        #expect(outcome(of: report, keptInFlight) == .created)
        let states = try await board.workflowStates(team: engineering.id)
        #expect(states.filter { $0.name == "Released" }.count == 1)
        #expect(states.first { $0.name == "Released" }?.category == .completed)

        let second = try await provision(board)
        #expect(outcome(of: second, released) == .collision("team"))
        let statesAfterSecond = try await board.workflowStates(team: engineering.id)
        #expect(statesAfterSecond.filter { $0.name == "Released" }.count == 1)
    }

    @Test("A Released of type started and a Released of type completed both existing is still a collision")
    func releasedCollidesWhenBothTypesExist() async throws {
        let board = board()
        await board.seed(state: "Released", team: engineering.id, category: .started)
        await board.seed(state: "Released", team: engineering.id, category: .completed)

        let report = try await provision(board)

        #expect(outcome(of: report, released) == .collision("team"))
    }

    @Test("An existing same-name state with nil category is a collision")
    func sameNameStateWithNilCategoryCollides() async throws {
        let board = board()
        await board.seed(state: "Released", team: engineering.id, category: nil)

        let report = try await provision(board)

        #expect(outcome(of: report, released) == .collision("team"))
    }

    @Test("The same (name, type) guard applies to Waiting on You too")
    func waitingOnYouCollidesWithAnotherType() async throws {
        let board = board()
        await board.seed(state: "Waiting on You", team: engineering.id, category: .unstarted)

        let report = try await provision(board)

        #expect(outcome(of: report, waitingOnYou) == .collision("team"))
    }
}
