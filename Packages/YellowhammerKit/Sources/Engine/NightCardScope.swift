import Domain

/// Where the Night Card is created and what marks it complete, resolved once per Act from the board's
/// provisioning surface: the team, the "Night Card" card-type label, and the workflow state to move
/// it to when the Night closes.
public struct NightCardScope: Equatable, Sendable {
    public let team: BoardObjectID
    public let nightCardLabel: BoardObjectID
    public let completedState: BoardObjectID

    public init(team: BoardObjectID, nightCardLabel: BoardObjectID, completedState: BoardObjectID) {
        self.team = team
        self.nightCardLabel = nightCardLabel
        self.completedState = completedState
    }

    /// Resolves the scope from the Project's Linear project.
    ///
    /// A Linear project spanning several teams creates the Night Card in the first team listed — the
    /// Linear project, not the team, is a Project's Night Card boundary (one per Project per Night).
    public static func resolve(using board: ActBoard) async throws -> NightCardScope {
        try await resolve(using: board.provisioning, mapping: board.mapping, footprint: board.footprint)
    }

    /// ``resolve(using:)-(ActBoard)`` for a bare provisioning surface and an explicit Board Mapping.
    public static func resolve(
        using board: any BoardProvisioning, mapping: BoardMapping = .empty,
        footprint: (any BoardFootprintStore)? = nil
    ) async throws -> NightCardScope {
        let project = try await board.linearProject()
        guard let team = project.teams.first else {
            throw NightCardScopeError.noTeam
        }
        let labels = try await board.labels(team: team.id)
        let known = BoardFootprintLookup.cardTypeLabelIDs(
            team: team.id, labels: labels, mapping: mapping, footprint: footprint
        )
        let nightCardLabel = try DispositionLabels(labels: labels, known: known).cardType[.nightCard]
        guard let nightCardLabel else {
            // DispositionLabels already verifies every declared child is present; this only guards
            // against its map changing shape underneath this call.
            throw DispositionLabelsError.missing(
                group: BoardProvisioner.cardTypeGroup, label: CardType.nightCard.rawValue
            )
        }
        let states = try await board.workflowStates(team: team.id)
        // The native Done: an explicit Board Mapping entry, else the lowest-position `completed` state.
        guard let completedState = NativeStateSelection.select(
            category: .completed, mapped: mapping[.completed], among: states, excluding: []
        ) else {
            throw NightCardScopeError.noCompletedState(team: team.id)
        }
        return NightCardScope(team: team.id, nightCardLabel: nightCardLabel, completedState: completedState.id)
    }
}

public enum NightCardScopeError: Error, Equatable, CustomStringConvertible {
    /// The Linear project has no team; a Night Card needs one to be created in.
    case noTeam
    /// No workflow state in the team reported the `completed` category.
    case noCompletedState(team: BoardObjectID)

    public var description: String {
        switch self {
        case .noTeam:
            "the Project's Linear project has no team to create the Night Card in"
        case .noCompletedState(let team):
            "team \(team) has no workflow state whose category is completed"
        }
    }
}
