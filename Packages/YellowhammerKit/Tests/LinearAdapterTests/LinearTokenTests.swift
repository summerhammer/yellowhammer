import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear client-credentials token")
struct LinearTokenTests {
    @Test("The token is requested once and reused across calls")
    func tokenIsReused() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer, Fixture.viewer])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.identity()
        _ = try await adapter.identity()

        let tokenRequests = transport.requests.filter { $0.url?.path == "/oauth/token" }
        #expect(tokenRequests.count == 1)
        #expect(transport.requests.count == 3)
    }

    @Test("The token is requested again once the clock passes expiry minus the skew")
    func tokenIsRefreshedBeforeExpiry() async throws {
        let transport = StubHTTPTransport([
            Fixture.token("first-token", expiresIn: 3600), Fixture.viewer,
            Fixture.viewer,
            Fixture.token("second-token", expiresIn: 3600), Fixture.viewer
        ])
        let clock = ManualClock()
        let adapter = Fixture.adapter(transport, clock: clock)

        _ = try await adapter.identity()
        clock.advance(by: 3600 - 61)
        _ = try await adapter.identity()
        clock.advance(by: 2)
        _ = try await adapter.identity()

        let paths = transport.requests.map { $0.url?.path ?? "" }
        #expect(paths == ["/oauth/token", "/graphql", "/graphql", "/oauth/token", "/graphql"])
        #expect(transport.requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer second-token")
    }

    @Test("The token request is form-encoded with the client-credentials grant and a scope")
    func tokenRequestIsFormEncoded() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer])
        _ = try await Fixture.adapter(transport).identity()

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.linear.app/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let data = try #require(request.httpBody)
        let body = try #require(String(bytes: data, encoding: .utf8))
        let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : "")
        })
        #expect(fields["grant_type"] == "client_credentials")
        #expect(fields["client_id"] == Fixture.clientID)
        #expect(fields["client_secret"] == Fixture.clientSecret)
        #expect(fields["scope"] == "read,write")
    }

    @Test("Every GraphQL request carries the bearer token")
    func graphQLRequestsCarryBearerToken() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer, Fixture.issues()])
        let adapter = Fixture.adapter(transport)
        _ = try await adapter.identity()
        _ = try await adapter.objects(updatedSince: nil)

        let graphQL = transport.requests.filter { $0.url?.absoluteString == "https://api.linear.app/graphql" }
        #expect(graphQL.count == 2)
        for request in graphQL {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.accessToken)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    @Test("The credentials' descriptions redact the client secret")
    func credentialsRedactTheSecret() {
        let credentials = Fixture.credentials
        #expect(!String(describing: credentials).contains(Fixture.clientSecret))
        #expect(!String(reflecting: credentials).contains(Fixture.clientSecret))
        #expect(String(describing: credentials).contains(Fixture.clientID))
    }

    @Test("identity() maps the viewer")
    func identityMapsViewer() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer])
        let identity = try await Fixture.adapter(transport).identity()
        #expect(identity == BoardIdentity(id: BoardObjectID(rawValue: "app-user-id"), name: "Yellowhammer"))
        let query = try #require(try Fixture.body(transport.requests[1])["query"] as? String)
        #expect(query.contains("viewer { id name }"))
    }
}
