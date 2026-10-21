import Domain

extension BoardProvisioner {
    /// The board a provisioning run reads, and whether it creates what is missing. Verification
    /// (`yh doctor`) runs the same checks as setup with `createsMissing` false, so the two can never
    /// disagree on what is present, missing or a collision.
    struct Target {
        let board: any BoardProvisioning
        let createsMissing: Bool
        /// The Project's store of persisted footprint ids and provenance; nil for a run that has none.
        var store: (any BoardFootprintStore)?
        /// The Board Mapping entries that passed verification; invalid ones are reported, never used.
        var mapping: BoardMapping = .empty
        /// Roles whose Board Mapping entry failed verification: reported, and never filled by a default,
        /// a created object or a name match in its place.
        var unusable: Set<BoardMappingRole> = []
        /// The ids earlier provisioning persisted.
        var persisted: [BoardFootprintRecord] = []

        /// The id of the `Card Type` label `name` that a Board Mapping entry or the persisted footprint names,
        /// when it is still a label (not a group) the team can see; nil to look the label up in its group.
        func labelOverride(_ name: String, among labels: [BoardLabel], team: BoardObjectID) -> BoardObjectID? {
            guard let type = CardType(rawValue: name) else { return nil }
            let role = BoardMappingRole(cardType: type)
            let candidates = [mapping[role], persisted.first { $0.team == team && $0.role == role }?.objectID]
            return candidates.compactMap { $0 }.first { id in labels.contains { $0.id == id && !$0.isGroup } }
        }

        func workflowStates(team: BoardObjectID) async throws(BoardError) -> [BoardWorkflowState] {
            try await board.workflowStates(team: team)
        }

        func labels(team: BoardObjectID) async throws(BoardError) -> [BoardLabel] {
            try await board.labels(team: team)
        }

        func createWorkflowState(
            name: String, category: BoardWorkflowStateCategory, team: BoardObjectID
        ) async throws(BoardError) -> BoardWorkflowState {
            try await board.createWorkflowState(name: name, category: category, team: team)
        }

        func createLabel(
            name: String, team: BoardObjectID, isGroup: Bool, parent: BoardObjectID?
        ) async throws(BoardError) -> BoardLabel {
            try await board.createLabel(name: name, team: team, isGroup: isGroup, parent: parent)
        }
    }

    /// Why verification reports an item `.missing`: setup has not created it yet.
    static let notProvisioned = "not provisioned; run `yh doctor --fix --check linear`"

    /// Verifies the Linear project's board without changing it: every item ``provision(using:projectName:createIn:)``
    /// would create is reported `.missing` instead, and every other outcome — present, collision,
    /// not a member — is reported exactly as setup reports it. Creates nothing.
    public static func verify(
        using board: any BoardProvisioning, projectName: String, footprint: BoardFootprintInputs = .none
    ) async throws(BoardError) -> ProvisioningReport {
        try await run(
            using: board, projectName: projectName, createIn: nil, createsMissing: false, footprint: footprint
        )
    }
}
