import Domain
import Foundation
import LinearAdapter
import Synchronization
import Testing

/// Pure GraphQL-response and transport-error translation (`LinearFailure`'s own job), exercised through
/// `Fixture.adapter` end to end. `Fixture.adapter` seeds a pair inside the 2-hour refresh window, so the
/// first call always refreshes first (request 0 = the token endpoint, request 1 = the first GraphQL
/// call) — every scripted reply list below assumes that shape. Deliberately excludes the
/// notAuthenticated-recovery path (one forced refresh + one retry): that belongs to
/// `LinearAdapterInstallationSendTests` (P17.3) and `LinearInstallationTokenSourceTests` (P17.4), since
/// it is the token source's own orchestration, not `LinearFailure`'s translation.
@Suite("Linear failure translation")
struct LinearFailureTests {
    /// Runs `identity()` or `objects` against the scripted replies and returns the thrown error,
    /// asserting it never carries either token.
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
                #expect(!text.contains(Fixture.accessToken), "access token leaked: \(text)")
                #expect(!text.contains(Fixture.refreshToken), "refresh token leaked: \(text)")
                #expect(!text.contains(Fixture.rotatedRefreshToken), "rotated refresh token leaked: \(text)")
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

    @Test("A 5xx refreshing the Installation's token is unreachable", arguments: [500, 502, 503, 504])
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
}
