import Domain

/// Where a Card's (and the Feature Issue's) workflow state lives on the board, resolved once per Act
/// from the board's provisioning surface: the team, a workflow state id for every writable
/// ``CardState``, and the disposition label catalogue.
///
/// Shelved is the one Card state Yellowhammer reads and never writes, so it is never in `states` and
/// every lookup for it throws rather than silently resolving to something.
public struct BoardStateScope: Equatable, Sendable {
    public let team: BoardObjectID
    /// A workflow state id for every writable ``CardState`` — everything but `.shelved`.
    public let states: [CardState: BoardObjectID]
    public let labels: DispositionLabels

    public init(team: BoardObjectID, states: [CardState: BoardObjectID], labels: DispositionLabels) {
        self.team = team
        self.states = states
        self.labels = labels
    }

    /// The workflow state id for `state`. Throws ``BoardStateScopeError/shelvedIsNeverWritten`` for
    /// `.shelved`.
    public func id(for state: CardState) throws -> BoardObjectID {
        guard state != .shelved else {
            throw BoardStateScopeError.shelvedIsNeverWritten
        }
        guard let id = states[state] else {
            throw BoardStateScopeError.stateNotProvisioned(name: state.rawValue, team: team)
        }
        return id
    }

    public subscript(state: CardState) -> BoardObjectID {
        get throws { try id(for: state) }
    }

    /// The CardState corresponding to a Feature returning to contention.
    public static let contentionCardState: CardState = .todo

    /// Resolves the workflow state id for a Feature returning to contention.
    public func contentionWorkflowStateID() throws -> BoardObjectID {
        try id(for: Self.contentionCardState)
    }

    /// The issue change that returns a Feature to contention: transitions to `.todo` (contention)
    /// and clears any Block Reason label.
    public func featureContentionChange() throws -> BoardIssueChange {
        var change = labels.change(cardType: .featureCard, state: Self.contentionCardState, blockReason: nil)
        change.workflowState = try contentionWorkflowStateID()
        return change
    }

    /// The states resolved by name first, falling back to a category match; Blocked and Waiting on You
    /// are provisioned by name only, so they never fall back.
    private static let writableStates: [CardState] = [.todo, .inProgress, .done, .blocked, .waitingOnYou]

    private static let categoryFallback: [CardState: BoardWorkflowStateCategory] = [
        .todo: .unstarted, .inProgress: .started, .done: .completed
    ]

    /// Resolves the scope from the Project's Linear project: first team of the Linear project, the
    /// disposition label catalogue, and every writable workflow state — exact name match first
    /// (case-insensitive), then the category fallback for Todo, In Progress and Done. Throws
    /// ``BoardStateScopeError/stateNotProvisioned(name:team:)`` for a state that resolves neither way.
    public static func resolve(using board: any BoardProvisioning) async throws -> BoardStateScope {
        let project = try await board.linearProject()
        guard let team = project.teams.first else {
            throw NightCardScopeError.noTeam
        }
        let boardStates = try await board.workflowStates(team: team.id)
        let boardLabels = try await board.labels(team: team.id)
        let labels = try DispositionLabels(labels: boardLabels)

        var states: [CardState: BoardObjectID] = [:]
        for state in writableStates {
            if let exact = boardStates.first(where: { $0.name.lowercased() == state.rawValue.lowercased() }) {
                states[state] = exact.id
                continue
            }
            if let category = categoryFallback[state],
               let byCategory = boardStates.first(where: { $0.category == category }) {
                states[state] = byCategory.id
                continue
            }
            throw BoardStateScopeError.stateNotProvisioned(name: state.rawValue, team: team.id)
        }
        return BoardStateScope(team: team.id, states: states, labels: labels)
    }
}

public enum BoardStateScopeError: Error, Equatable, CustomStringConvertible {
    /// Shelved is the one Card state Yellowhammer reads and never writes.
    case shelvedIsNeverWritten
    /// No workflow state in the team resolved to this Card state, by name or by category.
    case stateNotProvisioned(name: String, team: BoardObjectID)

    public var description: String {
        switch self {
        case .shelvedIsNeverWritten:
            "Shelved is the one Card state Yellowhammer reads and never writes"
        case .stateNotProvisioned(let name, let team):
            "team \(team) has no workflow state provisioned for '\(name)'"
        }
    }
}
