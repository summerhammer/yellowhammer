import Domain
import Foundation
import LinearAdapter
import Testing

/// The Installation's token behaviour as `LinearAdapter` itself exercises it — refresh timing and the
/// 2-hour window are `LinearInstallationTokenSourceTests`' own job (P17.4); this file covers what every
/// GraphQL request carries and how it decodes.
@Suite("Linear Installation token, through the adapter")
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

    @Test("The refresh request is form-encoded with the refresh_token grant and no client_secret")
    func refreshRequestIsFormEncoded() async throws {
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
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["client_id"] == LinearAppInstallation.clientID)
        #expect(fields["refresh_token"] != nil)
        #expect(fields["client_secret"] == nil)
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

    @Test("identity() maps the viewer")
    func identityMapsViewer() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer])
        let identity = try await Fixture.adapter(transport).identity()
        #expect(identity == BoardIdentity(id: BoardObjectID(rawValue: "app-user-id"), name: "Yellowhammer"))
        let query = try #require(try Fixture.body(transport.requests[1])["query"] as? String)
        #expect(query.contains("viewer { id name }"))
    }
}
