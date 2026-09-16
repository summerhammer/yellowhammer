import Foundation

/// Decoded payloads for provisioning queries.

struct LinearProjectPayload: Decodable {
    let project: LinearProjectData?
}

struct LinearProjectData: Decodable {
    let id: String
    let name: String
    let teams: LinearTeamsConnection
}

struct LinearTeamsConnection: Decodable {
    let nodes: [LinearTeamNode]
}

struct LinearTeamNode: Decodable {
    let id: String
    let key: String
    let name: String
}

struct LinearProjectCreatePayload: Decodable {
    let projectCreate: LinearProjectCreateData?
}

struct LinearProjectCreateData: Decodable {
    let success: Bool
    let project: LinearProjectCreateProjectData?
}

struct LinearProjectCreateProjectData: Decodable {
    let id: String
    let name: String
    let teams: LinearTeamsConnection
}

struct LinearWorkflowStatesPayload: Decodable {
    let workflowStates: LinearWorkflowStatesConnection
}

struct LinearWorkflowStatesConnection: Decodable {
    let pageInfo: LinearPageInfo
    let nodes: [LinearWorkflowStateNode]
}

struct LinearPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct LinearWorkflowStateNode: Decodable {
    let id: String
    let name: String
}

struct LinearWorkflowStateCreatePayload: Decodable {
    let workflowStateCreate: LinearWorkflowStateCreateData?
}

struct LinearWorkflowStateCreateData: Decodable {
    let success: Bool
    let workflowState: LinearWorkflowStateNode?
}

struct LinearLabelsPayload: Decodable {
    let issueLabels: LinearLabelsConnection
}

struct LinearLabelsConnection: Decodable {
    let pageInfo: LinearPageInfo
    let nodes: [LinearLabelNode]
}

struct LinearLabelNode: Decodable {
    let id: String
    let name: String
    let isGroup: Bool
    let parent: LinearParentLabel?
    let team: LinearTeamReference?
}

struct LinearParentLabel: Decodable {
    let id: String
}

struct LinearTeamReference: Decodable {
    let id: String
}

struct LinearLabelCreatePayload: Decodable {
    let issueLabelCreate: LinearLabelCreateData?
}

struct LinearLabelCreateData: Decodable {
    let success: Bool
    let issueLabel: LinearLabelNode?
}
