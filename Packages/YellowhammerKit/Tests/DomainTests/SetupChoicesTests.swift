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

    @Test("JSON without linearProjects decodes with an empty list") // glossary:ignore GL001
    func missingLinearProjectsDecodesEmpty() throws {
        let json = """
            {"operatorCandidates":[],"teams":[],"cliAdapters":["claude"]}
            """
        let decoded = try JSONDecoder().decode(SetupChoices.self, from: Data(json.utf8))
        #expect(decoded.linearProjects.isEmpty)
        #expect(decoded.configuredOperator == nil)
    }

    @Test("installations encode with the operator key, in a pinned shape")
    func installationsJSONShape() throws {
        let choices = SetupChoices(
            operatorCandidates: [], configuredOperator: nil, teams: [], cliAdapters: [],
            installations: [
                SetupChoices.Installation(name: "acme", workspace: "ws-1", operatorIdentity: "user-op"),
                SetupChoices.Installation(name: "beta", workspace: "ws-2", operatorIdentity: nil)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let json = try #require(String(data: encoder.encode(choices), encoding: .utf8))

        #expect(json == """
            {"cliAdapters":[],"installations":[{"name":"acme","operator":"user-op","workspace":"ws-1"},\
            {"name":"beta","workspace":"ws-2"}],"linearProjects":[],"operatorCandidates":[],"teams":[]}
            """)
        #expect(try JSONDecoder().decode(SetupChoices.self, from: Data(json.utf8)) == choices)
    }

    @Test("JSON without installations decodes with an empty registry")
    func missingInstallationsDecodesEmpty() throws {
        let json = #"{"operatorCandidates":[],"teams":[],"cliAdapters":["claude"]}"#
        let decoded = try JSONDecoder().decode(SetupChoices.self, from: Data(json.utf8))
        #expect(decoded.installations.isEmpty)
        #expect(decoded.linearProjectCheck == nil)
    }

    @Test("linearProjectCheck round-trips through JSON for found, notFound and noTeamAccess")
    func linearProjectCheckRoundTrips() throws {
        let foundChoices = SetupChoices(
            operatorCandidates: [], configuredOperator: nil, teams: [], cliAdapters: [],
            linearProjectCheck: .found(id: "proj-1", name: "Billing Revamp", teamNames: ["Engineering", "Payments"])
        )
        let foundData = try JSONEncoder().encode(foundChoices)
        let decodedFound = try JSONDecoder().decode(SetupChoices.self, from: foundData)
        #expect(decodedFound == foundChoices)
        #expect(decodedFound.linearProjectCheck?.status == .found)
        #expect(decodedFound.linearProjectCheck?.id == "proj-1")
        #expect(decodedFound.linearProjectCheck?.name == "Billing Revamp")
        #expect(decodedFound.linearProjectCheck?.teamNames == ["Engineering", "Payments"])

        let notFoundChoices = SetupChoices(
            operatorCandidates: [], configuredOperator: nil, teams: [], cliAdapters: [],
            linearProjectCheck: .notFound
        )
        let notFoundData = try JSONEncoder().encode(notFoundChoices)
        let decodedNotFound = try JSONDecoder().decode(SetupChoices.self, from: notFoundData)
        #expect(decodedNotFound == notFoundChoices)
        #expect(decodedNotFound.linearProjectCheck?.status == .notFound)
        #expect(decodedNotFound.linearProjectCheck?.id == nil)

        let noAccessChoices = SetupChoices(
            operatorCandidates: [], configuredOperator: nil, teams: [], cliAdapters: [],
            linearProjectCheck: .noTeamAccess(id: "proj-1", name: "Billing Revamp", teamNames: ["Payments"])
        )
        let noAccessData = try JSONEncoder().encode(noAccessChoices)
        let decodedNoAccess = try JSONDecoder().decode(SetupChoices.self, from: noAccessData)
        #expect(decodedNoAccess == noAccessChoices)
        #expect(decodedNoAccess.linearProjectCheck?.status == .noTeamAccess)
        #expect(decodedNoAccess.linearProjectCheck?.teamNames == ["Payments"])
    }
}
