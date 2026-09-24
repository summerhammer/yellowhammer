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
              id identifier title description url createdAt updatedAt archivedAt trashed
              state { id name type }
              labels { nodes { name } }
              parent { id }
              assignee { id }
            }
          }
        }
        """

    static let deltaReadQuery = """
        query YellowhammerDeltaRead(
          $projectId: String!,
          $issueFilter: IssueFilter!,
          $commentFilter: CommentFilter!,
          $first: Int!,
          $issuesAfter: String,
          $commentsAfter: String
        ) {
          project(id: $projectId) { id }
          viewer { id name }
          updatedIssues: issues(
            filter: $issueFilter, first: $first, after: $issuesAfter, orderBy: updatedAt, includeArchived: true
          ) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id identifier title description url createdAt updatedAt archivedAt trashed
              state { id name type }
              labels { nodes { name } }
              parent { id }
              assignee { id }
            }
          }
          newComments: comments(
            filter: $commentFilter, first: $first, after: $commentsAfter, orderBy: createdAt
          ) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id createdAt body
              parent { id }
              user { id name isMe }
              botActor { id name }
              issue { id identifier state { id name type } }
            }
          }
        }
        """

    /// A single issue by id, selecting the same fields the Delta Read's object selection does (settle
    /// gesture, roadmap P10.9): its workflow state is read fresh rather than waiting for the next
    /// Delta Read.
    static let issueByIDQuery = """
        query YellowhammerIssue($id: String!) {
          issue(id: $id) {
            id identifier title description url createdAt updatedAt archivedAt trashed
            state { id name type }
            labels { nodes { name } }
            parent { id }
            assignee { id }
          }
        }
        """

    /// Whether `id` is an active workspace member (roadmap P11.1, OQ66). Linear reports a nonexistent
    /// id as a GraphQL "not found" error, not a null `user`; ``LinearAdapter/isActiveMember(_:)``
    /// reads that as inactive.
    static let userQuery = """
        query YellowhammerUser($id: String!) {
          user(id: $id) { id active }
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
            nodes { id name type }
          }
        }
        """

    static let workflowStateCreateQuery = """
        mutation YellowhammerCreateWorkflowState($teamId: String!, $name: String!, $type: String!, $color: String!) {
          workflowStateCreate(input: { teamId: $teamId, name: $name, type: $type, color: $color }) {
            success
            workflowState { id name type }
          }
        }
        """

    /// `includeDisabled: true` so deactivated members are reported, never filtered by the adapter
    /// (Operator Identity Ruling, OQ66).
    static let usersQuery = """
        query YellowhammerUsers($first: Int!, $after: String) {
          users(first: $first, after: $after, includeDisabled: true) {
            pageInfo { hasNextPage endCursor }
            nodes { id name displayName active app isMe }
          }
        }
        """

    static let teamsQuery = """
        query YellowhammerTeams($first: Int!, $after: String) {
          teams(first: $first, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id key name }
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

    // MARK: - Writing Queries

    static let issueDescriptionQuery = """
        query YellowhammerIssueDescription($id: String!) {
          issue(id: $id) {
            id description updatedAt
            project { id }
          }
        }
        """

    static let createIssueQuery = """
        mutation YellowhammerCreateIssue($input: IssueCreateInput!) {
          issueCreate(input: $input) {
            success
            issue { id }
          }
        }
        """

    static let createCommentQuery = """
        mutation YellowhammerCreateComment($input: CommentCreateInput!) {
          commentCreate(input: $input) {
            success
            comment { id }
          }
        }
        """

    static let attachLinkQuery = """
        mutation YellowhammerAttachLink($id: String!, $issueId: String!, $url: String!, $title: String) {
          attachmentLinkURL(id: $id, issueId: $issueId, url: $url, title: $title) {
            success
            attachment { id }
          }
        }
        """

    /// Reads an issue's current label ids, so a removal can be filtered to labels Linear will actually
    /// accept removing (`issueUpdate` refuses the whole mutation if `removedLabelIds` names a label the
    /// issue does not carry).
    static let issueLabelsQuery = """
        query YellowhammerIssueLabels($id: String!) {
          issue(id: $id) {
            id
            labels { nodes { id } }
            project { id }
          }
        }
        """

    static let updateIssueQuery = """
        mutation YellowhammerUpdateIssue($id: String!, $input: IssueUpdateInput!) {
          issueUpdate(id: $id, input: $input) {
            success
            issue { id description updatedAt }
          }
        }
        """

    static let archiveIssueQuery = """
        mutation YellowhammerArchiveIssue($id: String!) {
          issueArchive(id: $id) {
            success
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
