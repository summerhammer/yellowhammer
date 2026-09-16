import Domain

/// Where the Night Card is created and what marks it complete, resolved once per Act from the board's
/// provisioning surface: the team, the "Night Card" object-type label, and the workflow state to move
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
    public static func resolve(using board: any BoardProvisioning) async throws -> NightCardScope {
        let project = try await board.linearProject()
        guard let team = project.teams.first else {
            throw NightCardScopeError.noTeam
        }
        let labels = try await board.labels(team: team.id)
        let nightCardLabel = try DispositionLabels(labels: labels).objectType["Night Card"]
        guard let nightCardLabel else {
            // DispositionLabels already verifies every declared child is present; this only guards
            // against its map changing shape underneath this call.
            throw DispositionLabelsError.missing(group: BoardProvisioner.objectTypeGroup, label: "Night Card")
        }
        let states = try await board.workflowStates(team: team.id)
        guard let completedState = states.first(where: { $0.category == .completed }) else {
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
