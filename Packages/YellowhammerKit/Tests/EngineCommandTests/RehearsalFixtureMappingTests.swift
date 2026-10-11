import Domain
@testable import Engine
import Testing

// #440: a rehearsal Night's selection and breakdown fixtures are re-aimed at the Project's own repository
// names and spec story IDs. Pure value tests: no I/O.

private func repo(_ name: String, role: RepoRole = .backend) -> Repo {
    Repo(name: name, path: "/repos/\(name)", role: role)
}

private func selected(_ repositories: [String]) -> SelectedFeature {
    SelectedFeature(
        name: FeatureName(rawValue: "Feature")!, reasoning: "Because.", sequence: nil,
        repositories: repositories, adoptedCardIssueIDs: ["X-1"]
    )
}

@Suite("RehearsalFixtureMapping (#440)")
struct RehearsalFixtureMappingTests {
    @Test("A Project with fixture-backend maps it to itself")
    func identityWhenNamesExist() {
        let mapping = RehearsalFixtureMapping(
            repos: [repo("fixture-backend"), repo("fixture-web", role: .web)], storyIDs: []
        )
        #expect(mapping.repositories["fixture-backend"] == "fixture-backend")
        #expect(mapping.repositories["fixture-web"] == "fixture-web")
        #expect(mapping.repositories["fixture-mobile"] == "fixture-backend")
    }

    @Test("Repos with other names are assigned positionally")
    func positional() {
        let mapping = RehearsalFixtureMapping(repos: [repo("app"), repo("web-app", role: .web)], storyIDs: [])
        #expect(mapping.repositories["fixture-backend"] == "app")
        #expect(mapping.repositories["fixture-web"] == "web-app")
        #expect(mapping.repositories["fixture-mobile"] == "app")
    }

    @Test("One repo: every fixture name wraps to it, and selection dedupes")
    func wrapsAndDedupes() {
        let mapping = RehearsalFixtureMapping(repos: [repo("app")], storyIDs: [])
        #expect(Set(mapping.repositories.values) == ["app"])
        let result = mapping.apply(to: selected(["fixture-backend", "fixture-web", "fixture-mobile"]))
        #expect(result.repositories == ["app"])
        #expect(result.adoptedCardIssueIDs == ["X-1"])
        #expect(result.name == selected([]).name)
    }

    @Test("A spec-role repo is never a target")
    func specRepoIsNeverATarget() {
        let mapping = RehearsalFixtureMapping(
            repos: [repo("the-spec", role: .spec), repo("app")], storyIDs: []
        )
        #expect(Set(mapping.repositories.values) == ["app"])
    }

    @Test("No repos leaves names untouched")
    func noReposUntouched() {
        let mapping = RehearsalFixtureMapping(repos: [], storyIDs: [])
        #expect(mapping.repositories.isEmpty)
        #expect(mapping.apply(to: selected(["fixture-backend"])).repositories == ["fixture-backend"])
    }

    @Test("Mixed: a Project with fixture-web and app maps backend to app and web to itself")
    func mixed() {
        let mapping = RehearsalFixtureMapping(repos: [repo("fixture-web", role: .web), repo("app")], storyIDs: [])
        #expect(mapping.repositories["fixture-backend"] == "app")
        #expect(mapping.repositories["fixture-web"] == "fixture-web")
    }

    @Test("Names outside the canonical lists pass through")
    func unknownPassesThrough() {
        let mapping = RehearsalFixtureMapping(repos: [repo("app")], storyIDs: ["demo/first"])
        #expect(mapping.apply(to: selected(["other"])).repositories == ["other"])
    }

    @Test("Citations: identity, positional, and untouched without stories")
    func citations() {
        let identity = RehearsalFixtureMapping(
            repos: [], storyIDs: ["fixture-epic/fixture-story-2", "fixture-epic/fixture-story"]
        )
        #expect(identity.citations["fixture-epic/fixture-story"] == "fixture-epic/fixture-story")
        #expect(identity.citations["fixture-epic/fixture-story-2"] == "fixture-epic/fixture-story-2")

        let positional = RehearsalFixtureMapping(repos: [], storyIDs: ["demo/first", "demo/second"])
        #expect(positional.citations["fixture-epic/fixture-story"] == "demo/first")
        #expect(positional.citations["fixture-epic/fixture-story-2"] == "demo/second")

        let wrapped = RehearsalFixtureMapping(repos: [], storyIDs: ["demo/first"])
        #expect(wrapped.citations["fixture-epic/fixture-story-2"] == "demo/first")

        #expect(RehearsalFixtureMapping(repos: [], storyIDs: []).citations.isEmpty)
    }

    @Test("A breakdown's Card and Contract repositories and both Definition of Done levels are mapped")
    func breakdownApply() {
        let mapping = RehearsalFixtureMapping(repos: [repo("app"), repo("site", role: .web)], storyIDs: ["demo/first"])
        let breakdown = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "F", citation: "fixture-epic/fixture-story")],
            cards: [CardDraft(
                repository: "fixture-web", kind: Kind("impl.fixture")!, title: "T", unitOfWork: "U", brief: "B",
                definitionOfDone: [DefinitionOfDoneClauseDraft(text: "C", citation: "fixture-epic/fixture-story-2")],
                contracts: [ContractDraft(
                    repository: "fixture-backend", paths: ["contracts/fixture-api.json"], symbol: "S"
                )]
            )]
        )

        let mapped = mapping.apply(to: breakdown)

        #expect(mapped.definitionOfDone.map(\.citation) == ["demo/first"])
        let card = mapped.cards[0]
        #expect(card.repository == "site")
        #expect(card.title == "T")
        #expect(card.definitionOfDone.map(\.citation) == ["demo/first"])
        let contract = ContractDraft(repository: "app", paths: ["contracts/fixture-api.json"], symbol: "S")
        #expect(card.contracts == [contract])
    }
}
