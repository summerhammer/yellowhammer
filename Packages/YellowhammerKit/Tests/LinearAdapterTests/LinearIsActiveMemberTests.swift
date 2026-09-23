import Domain
import Foundation
import LinearAdapter
import Testing

// The Operator identity's active-membership check (roadmap P11.1, OQ66).

@Suite("Linear isActiveMember")
struct LinearIsActiveMemberTests {
    @Test("An active user is reported active")
    func activeUser() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(), Fixture.json(#"{"data":{"user":{"id":"user-1","active":true}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        let active = try await adapter.isActiveMember(BoardObjectID(rawValue: "user-1"))

        #expect(active)
        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["id"] as? String == "user-1")
    }

    @Test("A deactivated user is reported inactive")
    func deactivatedUser() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(), Fixture.json(#"{"data":{"user":{"id":"user-1","active":false}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        let active = try await adapter.isActiveMember(BoardObjectID(rawValue: "user-1"))

        #expect(!active)
    }

    @Test("A user Linear reports as not found is reported inactive, not thrown")
    func userNotFound() async throws {
        let json = #"{"data":{"user":null},"# // glossary:ignore GL001
            + #""errors":[{"message":"Entity not found","extensions":{"code":"FORBIDDEN"}}]}"#
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json, status: 200)])
        let adapter = Fixture.adapter(transport)

        let active = try await adapter.isActiveMember(BoardObjectID(rawValue: "not-there"))

        #expect(!active)
    }
}
