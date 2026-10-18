import Domain
import Testing

private let issueUUID = "8f14e45f-ceea-467a-9575-1c5f0b1c2d3e"

private func instruction(
    _ pass: RunPass, boardState: SelectionBoardState?, adoption: [AdoptionCandidate] = []
) throws -> String {
    AuthoringInstruction(
        pass: pass, route: try #require(Route(cli: "claude", model: "opus", effort: "high")),
        specificationSource: .specSource(SpecSource(path: "/spec")), specificationMainline: nil,
        repos: [Repo(name: "backend", path: "/b", role: .backend)],
        mainlines: ResolvedMainlines(), namedFeature: nil, adoptionCandidates: adoption,
        refusedThisNight: [FeatureName(rawValue: "Refused one")].compactMap { $0 },
        selectedFeature: nil, boardState: boardState
    ).render()
}

private let populated = SelectionBoardState(
    features: [
        .init(name: "Pulse sidebar", identifier: "YLH-360", outcome: "landed"),
        .init(name: nil, identifier: "YLH-300", outcome: "abandoned")
    ],
    waitingCards: [
        .init(identifier: "YLH-361", title: "Wire the sidebar", repository: "backend", reason: "question")
    ]
)

@Suite("Authoring instruction: Board state")
struct AuthoringInstructionBoardStateTests {
    @Test("An empty board state, with no adoption candidates, renders the one line")
    func emptyBoardState() throws {
        let rendered = try instruction(.selection, boardState: SelectionBoardState())
        #expect(rendered.contains("## Board state\n\nNo Feature has been authored for this Project yet."))
    }

    @Test("A populated board state renders Features then Waiting on You Cards, in order, with no issue id")
    func populatedBoardState() throws {
        let rendered = try instruction(.selection, boardState: populated)
        #expect(rendered.contains(
            """
            ## Board state

            Features already authored for this Project, most recent first:

            - Pulse sidebar (YLH-360): landed
            - YLH-300: abandoned

            Cards in Waiting on You:

            - YLH-361 (repository: backend): Wire the sidebar — waiting on you: question
            """
        ))
        #expect(!rendered.contains(issueUUID))
        #expect(try instruction(.selection, boardState: populated) == rendered)
    }

    @Test("The section follows Adoption candidates and precedes Refused this Night")
    func sectionOrder() throws {
        let adoption = [AdoptionCandidate(issueID: issueUUID, repository: "backend")]
        let rendered = try instruction(.selection, boardState: populated, adoption: adoption)
        let adoptionAt = try #require(rendered.range(of: "## Adoption candidates"))
        let boardAt = try #require(rendered.range(of: "## Board state"))
        let refusedAt = try #require(rendered.range(of: "## Refused this Night"))
        #expect(adoptionAt.lowerBound < boardAt.lowerBound)
        #expect(boardAt.lowerBound < refusedAt.lowerBound)
    }

    @Test("The breakdown pass never renders the section, and a nil board state omits it")
    func breakdownAndNil() throws {
        #expect(!(try instruction(.breakdown, boardState: populated)).contains("## Board state"))
        #expect(!(try instruction(.selection, boardState: nil)).contains("## Board state"))
    }

    @Test("An adoption candidate names its title and Block Reason when known, and its bare form otherwise")
    func enrichedAdoptionBullets() throws {
        let adoption = [
            AdoptionCandidate(
                issueID: "a-1", repository: "backend", title: "Add retries", blockReason: "needs a decision"
            ),
            AdoptionCandidate(issueID: "a-2", repository: "backend")
        ]
        let rendered = try instruction(.selection, boardState: SelectionBoardState(), adoption: adoption)
        #expect(rendered.contains("- a-1 (repository: backend): Add retries — blocked: needs a decision\n"))
        #expect(rendered.contains("- a-2 (repository: backend)\n"))
        #expect(!rendered.contains("No Feature has been authored"))
        #expect(rendered.contains("Blocked Cards left by closed Features are listed under Adoption candidates."))
    }
}
