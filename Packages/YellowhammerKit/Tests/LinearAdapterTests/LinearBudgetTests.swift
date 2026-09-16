import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear rate-limit budget")
struct LinearBudgetTests {
    @Test("Budget headers parse into latestBudget, matched case-insensitively")
    func headersParse() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"viewer":{"id":"a","name":"Yellowhammer"}}}"#, headers: [
                "x-ratelimit-requests-limit": "5000",
                "X-RateLimit-Requests-Remaining": "4990",
                "x-ratelimit-requests-reset": "1800003600",
                "x-ratelimit-complexity-limit": "2000000",
                "x-ratelimit-complexity-remaining": "1999000",
                "x-ratelimit-complexity-reset": "1800003600000",
                "x-complexity": "12"
            ])
        ])
        let adapter = Fixture.adapter(transport)
        #expect(await adapter.latestBudget == nil)
        _ = try await adapter.identity()

        let budget = try #require(await adapter.latestBudget)
        #expect(budget == BoardBudget(
            requestsLimit: 5000,
            requestsRemaining: 4990,
            requestsResetAt: Date(timeIntervalSince1970: 1_800_003_600),
            complexityLimit: 2_000_000,
            complexityRemaining: 1_999_000,
            complexityResetAt: Date(timeIntervalSince1970: 1_800_003_600),
            lastRequestComplexity: 12
        ))
    }

    @Test("Missing and garbage budget headers yield nil fields and never fail the call")
    func missingAndGarbageHeaders() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"viewer":{"id":"a","name":"Yellowhammer"}}}"#, headers: [
                "x-ratelimit-requests-remaining": "4990",
                "x-ratelimit-requests-limit": "lots",
                "x-ratelimit-requests-reset": "tomorrow",
                "x-complexity": "1.5"
            ])
        ])
        let adapter = Fixture.adapter(transport)
        let identity = try await adapter.identity()
        #expect(identity.name == "Yellowhammer")

        let budget = try #require(await adapter.latestBudget)
        #expect(budget == BoardBudget(requestsRemaining: 4990))
    }

    @Test("A response with no budget headers at all does not fail")
    func noHeaders() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.viewer])
        let adapter = Fixture.adapter(transport)
        _ = try await adapter.identity()
        #expect(await adapter.latestBudget == nil)
    }
}
