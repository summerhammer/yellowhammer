import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

// roadmap P17.9 slice 2a: the remote-approval install flow (spec: board-projection/
// authorize-linear-via-remote-approval, ADR-006). Every side effect is injected — the relay's transport,
// the clock, and `sleep` — so polling and its deadline are testable without a real clock or network call.

private let relayBaseURL = URL(string: "https://relay.test")!

/// One scripted reply, keyed by how `RoutingTransport` classifies a request.
private enum Route: Hashable {
    case relaySession
    case relayStatus(String)
    case linearToken
    case linearGraphQL
}

/// Routes each request to a queue of scripted replies by host + path, rather than a single in-order
/// queue: the flow interleaves relay polls with (eventually) one Linear token/GraphQL call, so a single
/// FIFO queue can't express "N pending relay polls, then one Linear call".
private final class RoutingTransport: Sendable {
    private let queues: Mutex<[Route: [StubHTTPTransport.Reply]]>
    private let captured: Mutex<[URLRequest]>

    init(_ scripts: [Route: [StubHTTPTransport.Reply]]) {
        queues = Mutex(scripts)
        captured = Mutex([])
    }

    var requests: [URLRequest] { captured.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.withLock { $0.append(request) }
        let route = Self.classify(request)
        let reply = queues.withLock { queues -> StubHTTPTransport.Reply? in
            guard var replies = queues[route], !replies.isEmpty else { return nil }
            let reply = replies.removeFirst()
            queues[route] = replies
            return reply
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
            Issue.record("unscripted request for \(route): \(request.url?.absoluteString ?? "?")")
            throw URLError(.cannotConnectToHost)
        }
    }

    private static func classify(_ request: URLRequest) -> Route {
        let url = request.url!
        if url.host == relayBaseURL.host {
            if url.path == "/api/session" { return .relaySession }
            return .relayStatus(url.lastPathComponent)
        }
        if url.path == "/oauth/token" { return .linearToken }
        return .linearGraphQL
    }
}

/// A manual clock plus a `sleep` that advances it instead of actually waiting.
private final class PollClock: Sendable {
    private let now: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        now = Mutex(start)
    }

    func clock() -> Date { now.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        now.withLock { $0 = $0.addingTimeInterval(duration.timeIntervalForTest) }
    }
}

extension Duration {
    fileprivate var timeIntervalForTest: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

private func sessionReply(sessionID: String = "s1", expiresIn: Int = 900) -> StubHTTPTransport.Reply {
    .response(
        status: 201, headers: ["Content-Type": "application/json"],
        body: Data(
            (
                #"{"session_id":"\#(sessionID)","#
                    + #""install_url":"https://relay.test/install/\#(sessionID)","#
                    + #""expires_in":\#(expiresIn)}"#
            ).utf8
        )
    )
}

private func statusReply(_ body: String, status: Int = 200) -> StubHTTPTransport.Reply {
    .response(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
}

private let pendingReply = statusReply(#"{"status":"pending"}"#)
private let approvedReply = statusReply(#"{"status":"approved","code":"the-code"}"#)

private func tokenReply() -> StubHTTPTransport.Reply {
    .response(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(
            #"{"access_token":"at-1","refresh_token":"rt-1","token_type":"Bearer","expires_in":7200}"#.utf8
        )
    )
}

private func graphQLReply() -> StubHTTPTransport.Reply {
    .response(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(
            #"""
            {"data":{"viewer":{"id":"app-user-1","name":"Yellowhammer"},
             "organization":{"id":"workspace-1","name":"Acme","urlKey":"acme"}}}
            """#.utf8
        )
    )
}

/// Builds a flow whose relay and Linear calls both go through `transport`.
private func makeFlow(
    _ transport: RoutingTransport, clock: PollClock,
    events: @escaping @Sendable (LinearRemoteInstallFlow.Event) -> Void = { _ in },
    pollInterval: Duration = .seconds(4), deadlineGrace: Duration = .seconds(5)
) -> LinearRemoteInstallFlow {
    LinearRemoteInstallFlow(
        relay: CodeRelayClient(baseURL: relayBaseURL, transport: transport.send),
        transport: transport.send, clock: clock.clock, sleep: clock.sleep,
        pollInterval: pollInterval, deadlineGrace: deadlineGrace, events: events
    )
}

@Suite("LinearRemoteInstallFlow (P17.9)")
struct LinearRemoteInstallFlowTests {
    @Test("Happy path: create, pending, pending, approved gives .installed with the expected identity")
    func happyPathInstalls() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [pendingReply, pendingReply, approvedReply],
            .linearToken: [tokenReply()],
            .linearGraphQL: [graphQLReply()]
        ])
        let clock = PollClock()
        let capturedEvents = Mutex<[LinearRemoteInstallFlow.Event]>([])
        let flow = makeFlow(transport, clock: clock, events: { event in capturedEvents.withLock { $0.append(event) } })

        let outcome = try await flow.run()
        guard case .installed(let tokens, let identity) = outcome else {
            Issue.record("expected installed, got \(outcome)")
            return
        }
        #expect(tokens.accessToken == "at-1")
        #expect(identity.workspaceName == "Acme")
        #expect(identity.workspaceURLKey == "acme")

        let seen = capturedEvents.withLock { $0 }
        #expect(seen.count == 2)
        if case .approvalLinkIssued(let url, let expiresIn) = seen.first {
            #expect(url == URL(string: "https://relay.test/install/s1"))
            #expect(expiresIn == .seconds(900))
        } else {
            Issue.record("expected approvalLinkIssued first, got \(String(describing: seen.first))")
        }
        #expect(seen.last == .awaitingApproval)

        // No status GET after the approved poll.
        let statusRequests = transport.requests.filter { $0.url?.path == "/api/session/s1" }
        #expect(statusRequests.count == 3)
    }

    @Test("The token request body carries grant_type, the code, the relay redirect_uri and a code_verifier")
    func tokenRequestBodyShape() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [approvedReply],
            .linearToken: [tokenReply()],
            .linearGraphQL: [graphQLReply()]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        _ = try await flow.run()

        let tokenRequest = try #require(transport.requests.first { $0.url?.path == "/oauth/token" })
        let body = try #require(tokenRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=the-code"))
        #expect(body.contains("redirect_uri=https%3A%2F%2Fapp.yellowhammer.dev%2Fcallback"))
        #expect(body.contains("code_verifier="))
    }

    @Test("The verifier never reaches the relay, in any request or event")
    func verifierNeverReachesTheRelay() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [approvedReply],
            .linearToken: [tokenReply()],
            .linearGraphQL: [graphQLReply()]
        ])
        let clock = PollClock()
        let events = Mutex<[LinearRemoteInstallFlow.Event]>([])
        let flow = makeFlow(transport, clock: clock, events: { event in events.withLock { $0.append(event) } })
        _ = try await flow.run()

        let tokenRequest = try #require(transport.requests.first { $0.url?.path == "/oauth/token" })
        let body = try #require(tokenRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let verifierPair = try #require(
            body.split(separator: "&").first { $0.hasPrefix("code_verifier=") }
        )
        let verifier = String(verifierPair.dropFirst("code_verifier=".count))
        #expect(!verifier.isEmpty)

        for request in transport.requests where request.url?.host == relayBaseURL.host {
            #expect(request.url?.absoluteString.contains(verifier) != true)
            for (_, value) in request.allHTTPHeaderFields ?? [:] {
                #expect(!value.contains(verifier))
            }
            if let requestBody = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) {
                #expect(!requestBody.contains(verifier))
            }
        }
        for event in events.withLock({ $0 }) {
            #expect(!"\(event)".contains(verifier))
        }
    }

    @Test("An admin's rejection gives .rejected(access_denied)")
    func rejectionGivesRejected() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [statusReply(#"{"status":"rejected","error":"access_denied"}"#)]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        #expect(outcome == .rejected(error: "access_denied"))
    }

    @Test("A 404 on status gives .expired")
    func notFoundGivesExpired() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [statusReply("{}", status: 404)]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        #expect(outcome == .expired)
    }

    @Test("Pending until the deadline gives .expired, after roughly (expiresIn + grace) / pollInterval polls")
    func pendingUntilDeadlineExpires() async throws {
        let statuses = Mutex(0)
        let transport = RoutingTransport([
            .relaySession: [sessionReply(expiresIn: 900)],
            .relayStatus("s1"): Array(repeating: pendingReply, count: 400)
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock, pollInterval: .seconds(4), deadlineGrace: .seconds(5))
        let outcome = try await flow.run()
        #expect(outcome == .expired)

        let pollCount = transport.requests.filter { $0.url?.path == "/api/session/s1" }.count
        statuses.withLock { $0 = pollCount }
        // (900 + 5) / 4 ≈ 226; allow slack either side for the boundary check's off-by-one.
        #expect(pollCount > 200 && pollCount < 240)
    }

    @Test("503 on every status until the deadline gives .relayUnreachable")
    func persistentUnreachableExpires() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply(expiresIn: 20)],
            .relayStatus("s1"): Array(repeating: statusReply("{}", status: 503), count: 20)
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock, pollInterval: .seconds(4), deadlineGrace: .seconds(5))
        let outcome = try await flow.run()
        guard case .relayUnreachable = outcome else {
            Issue.record("expected relayUnreachable, got \(outcome)")
            return
        }
    }

    @Test("503, then 503, then approved gives .installed (transient tolerated)")
    func transientUnreachableIsTolerated() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [statusReply("{}", status: 503), statusReply("{}", status: 503), approvedReply],
            .linearToken: [tokenReply()],
            .linearGraphQL: [graphQLReply()]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        guard case .installed = outcome else {
            Issue.record("expected installed, got \(outcome)")
            return
        }
    }

    @Test("429 with Retry-After: 10 on status makes the flow sleep 10s rather than the 4s poll interval")
    func rateLimitedStatusUsesRetryAfter() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply(expiresIn: 30)],
            .relayStatus("s1"): [
                .response(status: 429, headers: ["Retry-After": "10"], body: Data()),
                approvedReply
            ],
            .linearToken: [tokenReply()],
            .linearGraphQL: [graphQLReply()]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock, pollInterval: .seconds(4), deadlineGrace: .seconds(5))
        let before = clock.clock()
        let outcome = try await flow.run()
        guard case .installed = outcome else {
            Issue.record("expected installed, got \(outcome)")
            return
        }
        // Only one sleep happened (the 429), and it must have been 10s, not 4s.
        #expect(clock.clock().timeIntervalSince(before) == 10)
    }

    @Test("A URLError at create gives .relayUnreachable")
    func createTransportErrorGivesUnreachable() async throws {
        let transport = RoutingTransport([.relaySession: [.failure(.notConnectedToInternet)]])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        guard case .relayUnreachable = outcome else {
            Issue.record("expected relayUnreachable, got \(outcome)")
            return
        }
    }

    @Test("429 at create gives .relayRateLimited")
    func createRateLimitedGivesRelayRateLimited() async throws {
        let transport = RoutingTransport([.relaySession: [statusReply("{}", status: 429)]])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        #expect(outcome == .relayRateLimited)
    }

    @Test("400 at create throws relayContract")
    func createBadResponseThrowsRelayContract() async throws {
        let transport = RoutingTransport([.relaySession: [statusReply(#"{"error":"bad"}"#, status: 400)]])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        await #expect(throws: LinearRemoteInstallFlow.FlowError.self) {
            _ = try await flow.run()
        }
    }

    @Test("A token exchange refused with HTTP 400 gives .notCompleted, with no further relay calls")
    func exchangeRefusalGivesNotCompleted() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [approvedReply],
            .linearToken: [statusReply("{}", status: 400)]
        ])
        let clock = PollClock()
        let flow = makeFlow(transport, clock: clock)
        let outcome = try await flow.run()
        guard case .notCompleted = outcome else {
            Issue.record("expected notCompleted, got \(outcome)")
            return
        }
        let statusRequests = transport.requests.filter { $0.url?.path == "/api/session/s1" }
        #expect(statusRequests.count == 1)
    }

    @Test("A sleep that throws CancellationError makes run() throw CancellationError, with no token request")
    func cancellationPropagates() async throws {
        let transport = RoutingTransport([
            .relaySession: [sessionReply()],
            .relayStatus("s1"): [pendingReply]
        ])
        let clock = PollClock()
        let flow = LinearRemoteInstallFlow(
            relay: CodeRelayClient(baseURL: relayBaseURL, transport: transport.send),
            transport: transport.send, clock: clock.clock,
            sleep: { _ in throw CancellationError() }
        )
        await #expect(throws: CancellationError.self) {
            _ = try await flow.run()
        }
        #expect(transport.requests.contains { $0.url?.path == "/oauth/token" } == false)
    }
}
