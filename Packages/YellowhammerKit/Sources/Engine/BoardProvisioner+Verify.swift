import Domain

extension BoardProvisioner {
    /// The board a provisioning run reads, and whether it creates what is missing. Verification
    /// (`yh doctor`) runs the same checks as setup with `createsMissing` false, so the two can never
    /// disagree on what is present, missing or a collision.
    struct Target {
        let board: any BoardProvisioning
        let createsMissing: Bool

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
    static let notProvisioned = "not provisioned; run `yh setup`"

    /// Verifies the Linear project's board without changing it: every item ``provision(using:projectName:createIn:routingTable:)``
    /// would create is reported `.missing` instead, and every other outcome — present, collision,
    /// not a member — is reported exactly as setup reports it. Creates nothing.
    public static func verify(
        using board: any BoardProvisioning, projectName: String, routingTable: RoutingTable? = nil
    ) async throws(BoardError) -> ProvisioningReport {
        try await run(
            using: board, projectName: projectName, createIn: nil, routingTable: routingTable, createsMissing: false
        )
    }
}
