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
    /// The team's native `canceled` state (the Card's Shelved, the Feature's abandonment), selected like the
    /// others. Kept out of ``states``: Yellowhammer reads Shelved and never writes it. Nil when the team has
    /// none, which preflight reports as an incomplete step.
    public let canceledState: BoardObjectID?

    public init(
        team: BoardObjectID, states: [CardState: BoardObjectID], labels: DispositionLabels,
        canceledState: BoardObjectID? = nil
    ) {
        self.team = team
        self.states = states
        self.labels = labels
        self.canceledState = canceledState
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
        var change = labels.change(cardType: .featureCard)
        change.workflowState = try contentionWorkflowStateID()
        return change
    }

    /// The Card states Yellowhammer writes, each resolved to a workflow state: Waiting on You and Blocked are
    /// Yellowhammer's two custom states; Todo, In Progress and Done are the team's native `unstarted`,
    /// `started` and `completed` states, selected by category (``NativeStateSelection``).
    private static let nativeCategory: [CardState: (BoardMappingRole, BoardWorkflowStateCategory)] = [
        .todo: (.unstarted, .unstarted), .inProgress: (.started, .started), .done: (.completed, .completed)
    ]

    /// Resolves the scope from the Project's Linear project: first team of the Linear project, the
    /// disposition label catalogue, and every writable workflow state.
    ///
    /// The two custom states come from a Board Mapping entry or the id persisted by earlier provisioning,
    /// re-verified present with category `started`; a name alone never selects one. The native three are
    /// selected by category: an explicit Board Mapping entry, else the lowest-position eligible state, a tie
    /// broken by state id; the custom ids and the legacy settlement states are excluded from generic
    /// `started` selection. Throws ``BoardStateScopeError/stateNotProvisioned(name:team:)`` for a state that
    /// resolves neither way.
    public static func resolve(using board: ActBoard) async throws -> BoardStateScope {
        try await resolve(using: board.provisioning, mapping: board.mapping, footprint: board.footprint)
    }

    /// ``resolve(using:)-(ActBoard)`` for a board with an explicit Board Mapping and footprint store (none:
    /// a board bound with no footprint, where the custom states fall back to name and `started` category).
    public static func resolve(
        using board: any BoardProvisioning, mapping: BoardMapping = .empty,
        footprint: (any BoardFootprintStore)? = nil
    ) async throws -> BoardStateScope {
        let project = try await board.linearProject()
        guard let team = project.teams.first else {
            throw NightCardScopeError.noTeam
        }
        let boardStates = try await board.workflowStates(team: team.id)
        let boardLabels = try await board.labels(team: team.id)
        let labels = try DispositionLabels(
            labels: boardLabels,
            known: BoardFootprintLookup.cardTypeLabelIDs(
                team: team.id, labels: boardLabels, mapping: mapping, footprint: footprint
            )
        )

        let customIDs = BoardFootprintLookup.customStateIDs(
            team: team.id, states: boardStates, mapping: mapping, footprint: footprint
        )
        var states: [CardState: BoardObjectID] = [:]
        for (state, role) in [(CardState.waitingOnYou, BoardMappingRole.waitingOnYou), (.blocked, .blocked)] {
            guard let id = customIDs[role] else {
                throw BoardStateScopeError.stateNotProvisioned(name: state.rawValue, team: team.id)
            }
            states[state] = id
        }
        let excluded = Set(customIDs.values)
        for (state, native) in nativeCategory {
            guard let selected = NativeStateSelection.select(
                category: native.1, mapped: mapping[native.0], among: boardStates, excluding: excluded
            ) else {
                throw BoardStateScopeError.stateNotProvisioned(name: state.rawValue, team: team.id)
            }
            states[state] = selected.id
        }
        let canceled = NativeStateSelection.select(
            category: .shelved, mapped: mapping[.canceled], among: boardStates, excluding: excluded
        )
        return BoardStateScope(team: team.id, states: states, labels: labels, canceledState: canceled?.id)
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
