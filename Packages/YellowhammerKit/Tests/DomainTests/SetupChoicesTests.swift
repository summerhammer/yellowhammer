import Domain
import Foundation
import Testing

struct SetupChoicesTests {
    @Test("SetupChoices round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let choices = SetupChoices(
            operatorCandidates: [
                SetupChoices.Member(id: "user-op", name: "operator", displayName: "Operator Person")
            ],
            configuredOperator: "user-op",
            teams: [SetupChoices.Team(id: "team-1", key: "ENG", name: "Engineering")],
            cliAdapters: ["claude", "codex"]
        )

        let data = try JSONEncoder().encode(choices)
        let decoded = try JSONDecoder().decode(SetupChoices.self, from: data)

        #expect(decoded == choices)
    }

    @Test("configuredOperator round-trips as nil")
    func configuredOperatorRoundTripsAsNil() throws {
        let choices = SetupChoices(operatorCandidates: [], configuredOperator: nil, teams: [], cliAdapters: [])

        let data = try JSONEncoder().encode(choices)
        let decoded = try JSONDecoder().decode(SetupChoices.self, from: data)

        #expect(decoded == choices)
    }
}
