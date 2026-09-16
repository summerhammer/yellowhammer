import Domain
import Testing

@testable import Engine

// board-projection (P5.8): the board state scope resolves a workflow state id for every writable Card
// state — by exact name first, falling back to category for Todo/In Progress/Done, but never for
// Blocked or Waiting on You, which are provisioned by name only — and refuses Cancelled outright
// (glossary → Cancelled: Yellowhammer reads it and never writes it).

private let scopeTeam = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")

private func board(withTeams teams: [BoardTeam] = [scopeTeam]) -> FakeProvisioningBoard {
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: teams)
    return FakeProvisioningBoard(project: scope)
}

@Suite("Board state scope")
struct BoardStateScopeTests {
    @Test("Every writable state resolves by exact name")
    func resolvesByName() async throws {
        let provisioning = board()
        let ids = try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .unstarted)

        let scope = try await BoardStateScope.resolve(using: provisioning)

        #expect(scope.team == scopeTeam.id)
        #expect(scope.labels.objectType["Card"] == ids["Card"])
        for state: CardState in [.todo, .inProgress, .done, .blocked, .waitingOnYou] {
            #expect(scope.states[state] != nil)
        }
    }

    @Test("Todo, In Progress and Done fall back to category when no state carries the name")
    func fallsBackByCategoryForTheThreeCoreStates() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Backlog", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Flight", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Shipped", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "Waiting on You", team: scopeTeam.id, category: .unstarted)

        let scope = try await BoardStateScope.resolve(using: provisioning)

        #expect(scope.states[.todo] != nil)
        #expect(scope.states[.inProgress] != nil)
        #expect(scope.states[.done] != nil)
    }

    @Test("A team without Waiting on You or Blocked refuses to resolve")
    func refusesMissingWaitingOnYouOrBlocked() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        // No "Blocked" state, and no other .unstarted/.started state that could be mistaken for it —
        // Blocked never falls back by category.

        await #expect(throws: BoardStateScopeError.stateNotProvisioned(name: "Blocked", team: scopeTeam.id)) {
            try await BoardStateScope.resolve(using: provisioning)
        }
    }

    @Test("Blocked and Waiting on You never fall back by category")
    func blockedAndWaitingOnYouNeverFallBackByCategory() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Blocked", team: scopeTeam.id, category: .unstarted)
        // An extra .unstarted state that is not named "Waiting on You": if the scope fell back by
        // category, this would wrongly resolve Waiting on You.
        await provisioning.seed(state: "Triage", team: scopeTeam.id, category: .unstarted)

        await #expect(throws: BoardStateScopeError.stateNotProvisioned(name: "Waiting on You", team: scopeTeam.id)) {
            try await BoardStateScope.resolve(using: provisioning)
        }
    }

    @Test("Cancelled is refused")
    func cancelledIsRefused() async throws {
        let provisioning = board()
        try await seedDispositionLabels(on: provisioning, team: scopeTeam.id)
        await provisioning.seed(state: "Todo", team: scopeTeam.id, category: .unstarted)
        await provisioning.seed(state: "In Progress", team: scopeTeam.id, category: .started)
        await provisioning.seed(state: "Done", team: scopeTeam.id, category: .completed)
        await provisioning.seed(state: "Blocked", team: scopeTeam.id)
        await provisioning.seed(state: "Waiting on You", team: scopeTeam.id)
        let scope = try await BoardStateScope.resolve(using: provisioning)

        #expect(throws: BoardStateScopeError.cancelledIsNeverWritten) {
            try scope.id(for: .cancelled)
        }
    }
}
