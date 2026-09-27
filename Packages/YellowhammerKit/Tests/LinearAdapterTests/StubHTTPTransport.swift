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
    static let accessToken = "lin_oauth_access-token-value"
    static let refreshToken = "lin_oauth_refresh-token-value"
    static let rotatedRefreshToken = "lin_oauth_rotated-refresh-token-value"
    static let linearProjectID = "7f1c2d9e-3b4a-4c5d-8e6f-0a1b2c3d4e5f"
    /// Linear's filter field for the Linear project scope.
    static let scopeKey = "project" // glossary:ignore GL001

    /// The Installation's token endpoint response for `Fixture.adapter`'s own always-stale seeded
    /// pair (P17.4): every test's first scripted reply is this refresh, keeping every existing
    /// request index unchanged from the client-credentials era (request 0 = token endpoint, request 1
    /// = the first GraphQL call).
    static func token(_ token: String = accessToken, expiresIn: Int = 2_591_999) -> StubHTTPTransport.Reply {
        json(#"""
            {"access_token":"\#(token)","refresh_token":"\#(rotatedRefreshToken)",
             "token_type":"Bearer","expires_in":\#(expiresIn),"scope":"read,write"}
            """#)
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

    /// A pair inside the 2-hour refresh window, so the very first `token()` call always refreshes —
    /// preserving the client-credentials era's "first request is always the token endpoint" shape that
    /// every existing test's request-index assertions depend on.
    static func stalePair(clock: ManualClock) -> LinearTokenPair {
        LinearTokenPair(
            accessToken: "stale-\(accessToken)", refreshToken: refreshToken,
            expiresAt: clock.read().addingTimeInterval(3600)
        )
    }

    static func adapter(
        _ transport: StubHTTPTransport,
        clock: ManualClock = ManualClock()
    ) -> LinearAdapter {
        let pair = Mutex<LinearTokenPair?>(stalePair(clock: clock))
        let store = LinearTokenStore(
            read: { pair.withLock { $0 } },
            write: { newValue in pair.withLock { $0 = newValue } },
            withRefreshLock: { try await $0() }
        )
        return LinearAdapter(
            linearProjectID: linearProjectID, tokenStore: store, transport: transport, clock: clock.read
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
