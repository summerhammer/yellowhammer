import Domain
import Foundation

// A neutral color for created workflow states; not a brand value.
private let provisioningWorkflowStateColor = "#95a2b3"

extension LinearAdapter: BoardProvisioning {
    public func workspaceMembers() async throws(BoardError) -> [BoardMember] {
        var allMembers: [BoardMember] = []
        var after: String?

        while true {
            var variables: [String: any Sendable] = ["first": 250]
            if let after {
                variables["after"] = after
            }
            let payload: LinearUsersPayload = try await perform(LinearGraphQL.usersQuery, variables: variables)
            allMembers.append(contentsOf: payload.users.nodes.map { node in
                BoardMember(
                    id: BoardObjectID(rawValue: node.id),
                    name: node.name,
                    displayName: node.displayName,
                    isActive: node.active,
                    isApp: node.app,
                    isSelf: node.isMe
                )
            })
            if !payload.users.pageInfo.hasNextPage {
                break
            }
            guard let endCursor = payload.users.pageInfo.endCursor else {
                throw .unreadableResponse("Linear indicated more results but provided no cursor")
            }
            after = endCursor
        }

        return allMembers
    }

    public func teams() async throws(BoardError) -> [BoardTeam] {
        var allTeams: [BoardTeam] = []
        var after: String?

        while true {
            var variables: [String: any Sendable] = ["first": 250]
            if let after {
                variables["after"] = after
            }
            let payload: LinearTeamsPayload = try await perform(LinearGraphQL.teamsQuery, variables: variables)
            allTeams.append(contentsOf: payload.teams.nodes.map { node in
                BoardTeam(id: BoardObjectID(rawValue: node.id), key: node.key, name: node.name)
            })
            if !payload.teams.pageInfo.hasNextPage {
                break
            }
            guard let endCursor = payload.teams.pageInfo.endCursor else {
                throw .unreadableResponse("Linear indicated more results but provided no cursor")
            }
            after = endCursor
        }

        return allTeams
    }

    public func linearProject() async throws(BoardError) -> BoardProjectScope {
        let payload: LinearProjectPayload = try await perform(
            LinearGraphQL.projectQuery, variables: ["id": linearProjectID]
        )
        guard let projectData = payload.project else {
            throw .scopeNotFound("Linear project not found")
        }
        return boardProjectScope(projectData)
    }

    public func createLinearProject(name: String, team: BoardObjectID) async throws(BoardError) -> BoardProjectScope {
        let payload: LinearProjectCreatePayload = try await perform(
            LinearGraphQL.projectCreateQuery, variables: ["name": name, "teamId": team.rawValue]
        )
        guard let createData = payload.projectCreate else {
            throw .refused("Linear project creation returned no data")
        }
        guard createData.success else {
            throw .refused("Linear refused to create the project") // glossary:ignore GL001
        }
        guard let projectData = createData.project else {
            throw .refused("Linear created the project but returned no project data") // glossary:ignore GL001
        }
        return BoardProjectScope(
            id: BoardObjectID(rawValue: projectData.id),
            name: projectData.name,
            teams: projectData.teams.nodes.map { node in
                BoardTeam(id: BoardObjectID(rawValue: node.id), key: node.key, name: node.name)
            }
        )
    }

    public func workflowStates(team: BoardObjectID) async throws(BoardError) -> [BoardWorkflowState] {
        var allStates: [BoardWorkflowState] = []
        var after: String?

        while true {
            var variables: [String: any Sendable] = ["teamId": team.rawValue, "first": 250]
            if let after {
                variables["after"] = after
            }
            let payload: LinearWorkflowStatesPayload = try await perform(
                LinearGraphQL.workflowStatesQuery, variables: variables
            )
            allStates.append(contentsOf: payload.workflowStates.nodes.map { node in
                BoardWorkflowState(
                    id: BoardObjectID(rawValue: node.id), name: node.name, category: Self.category(of: node.type)
                )
            })
            if !payload.workflowStates.pageInfo.hasNextPage {
                break
            }
            guard let endCursor = payload.workflowStates.pageInfo.endCursor else {
                throw .unreadableResponse("Linear indicated more results but provided no cursor")
            }
            after = endCursor
        }

        return allStates
    }

    public func createWorkflowState(
        name: String, category: BoardWorkflowStateCategory, team: BoardObjectID
    ) async throws(BoardError) -> BoardWorkflowState {
        let payload: LinearWorkflowStateCreatePayload = try await perform(
            LinearGraphQL.workflowStateCreateQuery,
            variables: [
                "teamId": team.rawValue,
                "name": name,
                "type": Self.vendorType(for: category),
                "color": provisioningWorkflowStateColor
            ]
        )
        guard let createData = payload.workflowStateCreate else {
            throw .refused("Linear workflow state creation returned no data")
        }
        guard createData.success else {
            throw .refused("Linear refused to create the workflow state")
        }
        guard let stateNode = createData.workflowState else {
            throw .refused("Linear created the workflow state but returned no state data")
        }
        return BoardWorkflowState(
            id: BoardObjectID(rawValue: stateNode.id), name: stateNode.name, category: Self.category(of: stateNode.type)
        )
    }

    /// Translates Linear's vendor `type` string into Yellowhammer's vocabulary. Linear spells its
    /// cancelled type `canceled`; an unrecognized string maps to nil rather than guessing. Shared
    /// with the issue queries' `boardObject(_:)` mapping so both translate `type` the same way.
    static func category(of type: String?) -> BoardWorkflowStateCategory? {
        guard let type else { return nil }
        if type == "canceled" { return .cancelled }
        return BoardWorkflowStateCategory(rawValue: type)
    }

    /// Translates Yellowhammer's category into Linear's vendor `type` string, the inverse of
    /// `category(of:)`. Linear spells its cancelled type `canceled`.
    private static func vendorType(for category: BoardWorkflowStateCategory) -> String {
        if category == .cancelled { return "canceled" }
        return category.rawValue
    }

    public func labels(team: BoardObjectID) async throws(BoardError) -> [BoardLabel] {
        var allLabels: [BoardLabel] = []
        var after: String?

        while true {
            var variables: [String: any Sendable] = ["teamId": team.rawValue, "first": 250]
            if let after {
                variables["after"] = after
            }
            let payload: LinearLabelsPayload = try await perform(
                LinearGraphQL.labelsQuery, variables: variables
            )
            allLabels.append(contentsOf: payload.issueLabels.nodes.map { node in
                BoardLabel(
                    id: BoardObjectID(rawValue: node.id),
                    name: node.name,
                    isGroup: node.isGroup,
                    parent: node.parent.map { BoardObjectID(rawValue: $0.id) },
                    team: node.team.map { BoardObjectID(rawValue: $0.id) }
                )
            })
            if !payload.issueLabels.pageInfo.hasNextPage {
                break
            }
            guard let endCursor = payload.issueLabels.pageInfo.endCursor else {
                throw .unreadableResponse("Linear indicated more results but provided no cursor")
            }
            after = endCursor
        }

        return allLabels
    }

    public func createLabel(
        name: String, team: BoardObjectID, isGroup: Bool, parent: BoardObjectID?
    ) async throws(BoardError) -> BoardLabel {
        var variables: [String: any Sendable] = [
            "teamId": team.rawValue,
            "name": name,
            "isGroup": isGroup
        ]
        if let parent {
            variables["parentId"] = parent.rawValue
        }
        let payload: LinearLabelCreatePayload = try await perform(
            LinearGraphQL.labelCreateQuery, variables: variables
        )
        guard let createData = payload.issueLabelCreate else {
            throw .refused("Linear label creation returned no data")
        }
        guard createData.success else {
            throw .refused("Linear refused to create the label")
        }
        guard let labelNode = createData.issueLabel else {
            throw .refused("Linear created the label but returned no label data")
        }
        return BoardLabel(
            id: BoardObjectID(rawValue: labelNode.id),
            name: labelNode.name,
            isGroup: labelNode.isGroup,
            parent: labelNode.parent.map { BoardObjectID(rawValue: $0.id) },
            team: labelNode.team.map { BoardObjectID(rawValue: $0.id) }
        )
    }

    private func boardProjectScope(_ projectData: LinearProjectData) -> BoardProjectScope {
        BoardProjectScope(
            id: BoardObjectID(rawValue: projectData.id),
            name: projectData.name,
            teams: projectData.teams.nodes.map { node in
                BoardTeam(id: BoardObjectID(rawValue: node.id), key: node.key, name: node.name)
            }
        )
    }
}
