import Foundation
import LinearAdapter
import Synchronization
import Testing

/// Plays back scripted responses in order and records every request it received.
final class StubHTTPTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError.Code)
    }

    private struct State {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ replies: [Reply]) {
        state = Mutex(State(replies: replies))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        switch reply {
        case .response(let status, let headers, let body)?:
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, response)
        case .failure(let code)?:
            throw URLError(code)
        case nil:
            throw URLError(.cannotConnectToHost)
        }
    }
}

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let now: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        now = Mutex(start)
    }

    func advance(by seconds: TimeInterval) {
        now.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var read: @Sendable () -> Date {
        { self.now.withLock { $0 } }
    }
}

enum Fixture {
    static let clientID = "yellowhammer-client-id"
    static let clientSecret = "s3cr3t-client-secret-value"
    static let accessToken = "lin_oauth_access-token-value"
    static let linearProjectID = "7f1c2d9e-3b4a-4c5d-8e6f-0a1b2c3d4e5f"
    /// Linear's filter field for the Linear project scope.
    static let scopeKey = "project" // glossary:ignore GL001

    static var credentials: LinearCredentials {
        LinearCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    static func token(_ token: String = accessToken, expiresIn: Int = 2_591_999) -> StubHTTPTransport.Reply {
        json(#"{"access_token":"\#(token)","token_type":"Bearer","expires_in":\#(expiresIn),"scope":"read,write"}"#)
    }

    static func json(
        _ body: String, status: Int = 200, headers: [String: String] = [:]
    ) -> StubHTTPTransport.Reply {
        let headers = headers.merging(["Content-Type": "application/json"]) { $1 }
        return .response(status: status, headers: headers, body: Data(body.utf8))
    }

    static let viewer = json(#"{"data":{"viewer":{"id":"app-user-id","name":"Yellowhammer"}}}"#)

    /// The Installation's token endpoint response shape (P17.3, ADR-005): access + refresh token.
    static func installationGrant(
        accessToken: String, refreshToken: String, expiresIn: Int = 7200, status: Int = 200
    ) -> StubHTTPTransport.Reply {
        json(
            #"""
            {"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)",
             "token_type":"Bearer","expires_in":\#(expiresIn)}
            """#,
            status: status
        )
    }

    static func issues(
        hasNextPage: Bool = false, endCursor: String? = nil, nodes: String = ""
    ) -> StubHTTPTransport.Reply {
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        return json("""
            {"data":{"\(scopeKey)":{"id":"\(linearProjectID)"},"issues":{
              "pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor)},
              "nodes":[\(nodes)]}}}
            """)
    }

    static func adapter(
        _ transport: StubHTTPTransport,
        clock: ManualClock = ManualClock(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> LinearAdapter {
        LinearAdapter(
            linearProjectID: linearProjectID, credentials: credentials, transport: transport, clock: clock.read,
            sleep: sleep
        )
    }

    /// The JSON body of a GraphQL request.
    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func variables(_ request: URLRequest) throws -> [String: Any] {
        try #require(try body(request)["variables"] as? [String: Any])
    }

    static func delta(
        issueNodes: String = "",
        issueHasNextPage: Bool = false,
        issueEndCursor: String? = nil,
        commentNodes: String = "",
        commentHasNextPage: Bool = false,
        commentEndCursor: String? = nil
    ) -> StubHTTPTransport.Reply {
        let issueCursor = issueEndCursor.map { "\"\($0)\"" } ?? "null"
        let commentCursor = commentEndCursor.map { "\"\($0)\"" } ?? "null"
        return json("""
            {"data":{"viewer":{"id":"app-user-id","name":"Yellowhammer"},
              "updatedIssues":{"pageInfo":{"hasNextPage":\(issueHasNextPage),"endCursor":\(issueCursor)},
              "nodes":[\(issueNodes)]},
              "newComments":{"pageInfo":{"hasNextPage":\(commentHasNextPage),"endCursor":\(commentCursor)},
              "nodes":[\(commentNodes)]}}}
            """)
    }
}
