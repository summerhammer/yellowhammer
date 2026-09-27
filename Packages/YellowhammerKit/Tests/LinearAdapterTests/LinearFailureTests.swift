import Domain
import Foundation
import LinearAdapter
import Synchronization
import Testing

@Suite("Linear failure translation")
struct LinearFailureTests {
    /// Runs `identity()` or `objects` against the scripted replies and returns the thrown error,
    /// asserting it never carries the client secret or the access token.
    private func failure(
        _ replies: [StubHTTPTransport.Reply], readObjects: Bool = false
    ) async throws -> BoardError {
        let adapter = Fixture.adapter(StubHTTPTransport(replies))
        do {
            if readObjects {
                _ = try await adapter.objects(updatedSince: nil)
            } else {
                _ = try await adapter.identity()
            }
        } catch {
            for text in [error.description, String(reflecting: error)] {
                #expect(!text.contains(Fixture.clientSecret), "secret leaked: \(text)")
                #expect(!text.contains(Fixture.accessToken), "token leaked: \(text)")
            }
            return error
        }
        Issue.record("expected the call to fail")
        return .refused("no failure")
    }

    @Test("HTTP 429 is rateLimited, with retry-after and the budget")
    func http429() async throws {
        let error = try await failure([
            Fixture.token(),
            Fixture.json(#"{"errors":[{"message":"Too many"}]}"#, status: 429, headers: [
                "Retry-After": "30", "x-ratelimit-requests-remaining": "0", "x-ratelimit-requests-limit": "5000"
            ])
        ])
        #expect(error == .rateLimited(
            retryAfter: .seconds(30), budget: BoardBudget(requestsLimit: 5000, requestsRemaining: 0)
        ))
    }

    @Test("A GraphQL RATELIMITED code is rateLimited, and the budget is recorded")
    func graphQLRateLimited() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}"#,
                status: 400, headers: ["x-ratelimit-complexity-remaining": "0"]
            )
        ])
        let adapter = Fixture.adapter(transport)
        await #expect(throws: BoardError.rateLimited(retryAfter: nil, budget: BoardBudget(complexityRemaining: 0))) {
            _ = try await adapter.identity()
        }
        #expect(await adapter.latestBudget == BoardBudget(complexityRemaining: 0))
    }

    @Test("HTTP 401 is notAuthenticated")
    func http401() async throws {
        let error = try await failure([Fixture.token(), Fixture.json(#"{"errors":[]}"#, status: 401)])
        guard case .notAuthenticated = error else {
            Issue.record("expected notAuthenticated, got \(error)")
            return
        }
    }

    @Test("A refusal at the OAuth token endpoint is notAuthenticated")
    func tokenEndpointRefusal() async throws {
        let reply = Fixture.json(
            #"{"error":"invalid_client","error_description":"bad \#(Fixture.clientSecret)"}"#, status: 401
        )
        let error = try await failure([reply, reply])
        guard case .notAuthenticated(let message) = error else {
            Issue.record("expected notAuthenticated, got \(error)")
            return
        }
        #expect(message.contains("invalid_client"))
    }

    @Test("An intermittent invalid_client at the OAuth token endpoint retries once and succeeds")
    func intermittentInvalidClientRetries() async throws {
        let sleptDurations = Mutex<[Duration]>([])
        let transport = StubHTTPTransport([
            Fixture.json(#"{"error":"invalid_client","error_description":"temporary hiccup"}"#, status: 400),
            Fixture.token("retried-token"),
            Fixture.viewer
        ])
        let adapter = Fixture.adapter(transport, sleep: { duration in
            sleptDurations.withLock { $0.append(duration) }
        })
        let identity = try await adapter.identity()
        #expect(identity == BoardIdentity(id: BoardObjectID(rawValue: "app-user-id"), name: "Yellowhammer"))
        #expect(sleptDurations.withLock { $0 } == [.milliseconds(250)])
        #expect(transport.requests.count == 3)
        #expect(transport.requests[0].url?.path == "/oauth/token")
        #expect(transport.requests[1].url?.path == "/oauth/token")
        #expect(transport.requests[2].url?.path == "/graphql")
    }

    @Test("A 5xx at the OAuth token endpoint is unreachable", arguments: [500, 502, 503, 504])
    func tokenEndpoint5xx(statusCode: Int) async throws {
        let error = try await failure([
            Fixture.json("Service Unavailable", status: statusCode)
        ])
        guard case .unreachable(let message) = error else {
            Issue.record("expected unreachable, got \(error)")
            return
        }
        #expect(message.contains("\(statusCode)"))
    }

    @Test("A GraphQL 5xx is unreachable", arguments: [500, 502, 503, 504])
    func graphQL5xx(statusCode: Int) async throws {
        let error = try await failure([
            Fixture.token(),
            Fixture.json("Server Error", status: statusCode)
        ])
        guard case .unreachable(let message) = error else {
            Issue.record("expected unreachable, got \(error)")
            return
        }
        #expect(message.contains("\(statusCode)"))
    }

    @Test("A GraphQL entity-not-found for the Linear project is scopeNotFound")
    func entityNotFound() async throws {
        let body = #"""
            {"errors":[{"message":"Entity not found: Project",
              "extensions":{"type":"invalid input","code":"INVALID_INPUT",
              "userPresentableMessage":"Could not find referenced Project."}}],"data":null}
            """#
        let error = try await failure([Fixture.token(), Fixture.json(body)], readObjects: true)
        guard case .scopeNotFound = error else {
            Issue.record("expected scopeNotFound, got \(error)")
            return
        }
    }

    @Test("A GraphQL FORBIDDEN code is forbidden, never scopeNotFound")
    func graphQLForbidden() async throws {
        let body = #"""
            {"errors":[{"message":"You are not allowed to create workflow states for this team",
              "extensions":{"code":"FORBIDDEN"}}]}
            """#
        let error = try await failure([Fixture.token(), Fixture.json(body)])
        guard case .forbidden(let message) = error else {
            Issue.record("expected forbidden, got \(error)")
            return
        }
        #expect(message.contains("not allowed"))
    }

    @Test("HTTP 403 is forbidden, not notAuthenticated")
    func http403() async throws {
        let error = try await failure([Fixture.token(), Fixture.json(#"{"errors":[]}"#, status: 403)])
        guard case .forbidden = error else {
            Issue.record("expected forbidden, got \(error)")
            return
        }
    }

    @Test("Another GraphQL error is refused, with a translated message that never echoes the token")
    func otherGraphQLError() async throws {
        let body = #"{"errors":[{"message":"Bad \#(Fixture.accessToken)","extensions":{"code":"INVALID_INPUT"}}]}"#
        let error = try await failure([Fixture.token(), Fixture.json(body)])
        guard case .refused(let message) = error else {
            Issue.record("expected refused, got \(error)")
            return
        }
        #expect(message.contains("INVALID_INPUT"))
    }

    @Test("A transport error is unreachable", arguments: [false, true])
    func transportError(atTokenEndpoint: Bool) async throws {
        let replies: [StubHTTPTransport.Reply] = atTokenEndpoint
            ? [.failure(.notConnectedToInternet)]
            : [Fixture.token(), .failure(.timedOut)]
        let error = try await failure(replies)
        guard case .unreachable = error else {
            Issue.record("expected unreachable, got \(error)")
            return
        }
    }

    @Test("Malformed JSON is unreadableResponse", arguments: [false, true])
    func malformedJSON(atTokenEndpoint: Bool) async throws {
        let replies: [StubHTTPTransport.Reply] = atTokenEndpoint
            ? [Fixture.json("{not json")]
            : [Fixture.token(), Fixture.json(#"{"data":{"issues":{"nodes":"oops"}}}"#)]
        let error = try await failure(replies, readObjects: true)
        guard case .unreadableResponse = error else {
            Issue.record("expected unreadableResponse, got \(error)")
            return
        }
    }

    @Test("A refused access token is dropped, so the next call obtains a new one")
    func refusedTokenIsDropped() async throws {
        let transport = StubHTTPTransport([
            Fixture.token("stale-token"), Fixture.json("{}", status: 401),
            Fixture.token("fresh-token"), Fixture.viewer
        ])
        let adapter = Fixture.adapter(transport)
        await #expect(throws: BoardError.self) { _ = try await adapter.identity() }
        _ = try await adapter.identity()
        #expect(transport.requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }
}
