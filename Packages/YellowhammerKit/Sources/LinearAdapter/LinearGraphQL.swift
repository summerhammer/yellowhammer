import Foundation

/// Linear's GraphQL endpoint: request construction and the `{ data, errors }` envelope.
enum LinearGraphQL {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    static func request(query: String, variables: [String: any Sendable], token: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return request
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = timestamp(string) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 timestamp")
            )
        }
        return decoder
    }

    static func timestamp(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    static func timestampString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: - Queries

    static let viewerQuery = "query YellowhammerIdentity { viewer { id name } }"

    /// `project(id:)` rides along so that a Linear project this identity cannot see fails as not found,
    /// instead of reading as an empty page.
    static let issuesQuery = """
        query YellowhammerBoardObjects($projectId: String!, $filter: IssueFilter!, $first: Int!, $after: String) {
          project(id: $projectId) { id }
          issues(filter: $filter, first: $first, after: $after, orderBy: updatedAt) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id identifier title description url createdAt updatedAt
              state { id name }
              labels { nodes { name } }
              parent { id }
            }
          }
        }
        """

    // MARK: - Provisioning Queries

    static let projectQuery = """
        query YellowhammerProject($id: String!) {
          project(id: $id) {
            id name
            teams { nodes { id key name } }
          }
        }
        """

    static let projectCreateQuery = """
        mutation YellowhammerCreateProject($name: String!, $teamId: String!) {
          projectCreate(input: { name: $name, teamIds: [$teamId] }) {
            success
            project {
              id name
              teams { nodes { id key name } }
            }
          }
        }
        """

    static let workflowStatesQuery = """
        query YellowhammerWorkflowStates($teamId: ID!, $first: Int!, $after: String) {
          workflowStates(filter: { team: { id: { eq: $teamId } } }, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id name }
          }
        }
        """

    static let workflowStateCreateQuery = """
        mutation YellowhammerCreateWorkflowState($teamId: String!, $name: String!, $color: String!) {
          workflowStateCreate(input: { teamId: $teamId, name: $name, type: "started", color: $color }) {
            success
            workflowState { id name }
          }
        }
        """

    static let labelsQuery = """
        query YellowhammerLabels($teamId: ID!, $first: Int!, $after: String) {
          issueLabels(filter: { or: [
            { team: { id: { eq: $teamId } } },
            { team: { null: true } }
          ] }, first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id name isGroup
              parent { id }
              team { id }
            }
          }
        }
        """

    static let labelCreateQuery = """
        mutation YellowhammerCreateLabel($teamId: String!, $name: String!, $isGroup: Boolean!, $parentId: String) {
          issueLabelCreate(input: { teamId: $teamId, name: $name, isGroup: $isGroup, parentId: $parentId }) {
            success
            issueLabel {
              id name isGroup
              parent { id }
              team { id }
            }
          }
        }
        """
}

/// The `{ data, errors }` envelope of every GraphQL response.
struct LinearGraphQLEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [LinearGraphQLError]?
}

/// One entry of a GraphQL response's `errors[]`. Never leaves the module: ``LinearFailure`` translates it.
struct LinearGraphQLError: Decodable {
    let message: String?
    let extensions: Extensions?

    struct Extensions: Decodable {
        let code: String?
        let type: String?
        let userPresentableMessage: String?
    }
}
