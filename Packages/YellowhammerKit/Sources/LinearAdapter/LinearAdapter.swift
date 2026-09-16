import Domain
import Foundation

/// The Linear implementation of the Board Port, bound at construction to one Project's Linear project.
///
/// It authenticates as the registered Linear OAuth application through the client-credentials grant,
/// records the budget every response reports, and translates every failure into ``BoardError``. It
/// translates and never decides: no retry, no Outbox, no Lease.
public actor LinearAdapter: Board {
    let linearProjectID: String
    private let transport: any HTTPTransport
    private let tokens: LinearTokenSource

    public private(set) var latestBudget: BoardBudget?

    public init(
        linearProjectID: String,
        credentials: LinearCredentials,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.linearProjectID = linearProjectID
        self.transport = transport
        tokens = LinearTokenSource(credentials: credentials, transport: transport, clock: clock)
    }

    /// The outcome of a GraphQL request that may succeed, fail, or encounter a conflict on insert.
    enum LinearOutcome<Payload> {
        case payload(Payload)
        case insertConflict
    }

    public func identity() async throws(BoardError) -> BoardIdentity {
        let payload: LinearViewerPayload = try await perform(LinearGraphQL.viewerQuery, variables: [:])
        return BoardIdentity(id: BoardObjectID(rawValue: payload.viewer.id), name: payload.viewer.name)
    }

    public func objects(
        updatedSince: Date?, after: BoardCursor?, pageSize: Int
    ) async throws(BoardError) -> BoardPage {
        // The Linear project scope is in every read; the key is Linear's filter field.
        var filter: [String: any Sendable] = ["project": ["id": ["eq": linearProjectID]]] // glossary:ignore GL001
        if let updatedSince {
            filter["updatedAt"] = ["gt": LinearGraphQL.timestampString(updatedSince)]
        }
        var variables: [String: any Sendable] = ["projectId": linearProjectID, "filter": filter, "first": pageSize]
        if let after {
            variables["after"] = after.rawValue
        }
        let payload: LinearIssuesPayload = try await perform(LinearGraphQL.issuesQuery, variables: variables)
        let issues = payload.issues
        return BoardPage(
            objects: issues.nodes.map(Self.boardObject),
            nextCursor: issues.pageInfo.hasNextPage ? issues.pageInfo.endCursor.map(BoardCursor.init) : nil
        )
    }

    private static func boardObject(_ issue: LinearIssuesPayload.Issue) -> BoardObject {
        BoardObject(
            id: BoardObjectID(rawValue: issue.id),
            key: issue.identifier,
            title: issue.title,
            description: issue.description,
            workflowState: BoardWorkflowState(id: BoardObjectID(rawValue: issue.state.id), name: issue.state.name),
            labels: issue.labels.nodes.map(\.name),
            parent: issue.parent.map { BoardObjectID(rawValue: $0.id) },
            url: issue.url,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt
        )
    }

    /// One authenticated GraphQL request that may encounter a conflict on insert. The budget is recorded
    /// before the outcome is judged, because a refusal is exactly when it matters.
    func send<Payload: Decodable>(
        _ query: String, variables: [String: any Sendable]
    ) async throws(BoardError) -> LinearOutcome<Payload> {
        let token = try await tokens.token()
        let failure = LinearFailure(secrets: await tokens.secrets)

        let request: URLRequest
        do {
            request = try LinearGraphQL.request(query: query, variables: variables, token: token)
        } catch {
            throw .refused("the request to Linear could not be encoded")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw failure.transport(error)
        }
        if let budget = LinearBudget.parse(response) {
            latestBudget = budget
        }
        // Check for conflict before other judgements, since conflict may come with 200 or 400.
        if failure.insertConflict(data) {
            return .insertConflict
        }
        // GraphQL errors are judged before the payload: a failed query may carry a `data` too partial to decode.
        if let refusal = failure.status(data, response) ?? failure.graphQL(data, response) {
            if case .notAuthenticated = refusal {
                await tokens.invalidate()
            }
            throw refusal
        }
        let envelope: LinearGraphQLEnvelope<Payload>
        do {
            envelope = try LinearGraphQL.decoder().decode(LinearGraphQLEnvelope<Payload>.self, from: data)
        } catch {
            throw failure.unreadable(error)
        }
        guard let payload = envelope.data else {
            throw .unreadableResponse("Linear's response carried neither data nor errors")
        }
        return .payload(payload)
    }

    /// One authenticated GraphQL request. The budget is recorded before the outcome is judged, because a
    /// refusal is exactly when it matters. A conflict on insert is reported as refused.
    func perform<Payload: Decodable>(
        _ query: String, variables: [String: any Sendable]
    ) async throws(BoardError) -> Payload {
        let outcome: LinearOutcome<Payload> = try await send(query, variables: variables)
        switch outcome {
        case .payload(let payload):
            return payload
        case .insertConflict:
            throw .refused("Linear has already processed this write")
        }
    }
}
