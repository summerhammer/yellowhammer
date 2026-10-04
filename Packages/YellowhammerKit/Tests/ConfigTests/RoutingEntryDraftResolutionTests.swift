import Config
import Domain
import Testing

private func route(_ cli: String, _ model: String, _ effort: String) -> RouteDraft {
    RouteDraft(cli: cli, model: model, effort: effort)
}

private func kind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

private let sonnet = route("claude", "sonnet", "medium")
private let opus = route("claude", "opus", "high")
private let codex = route("codex", "gpt-5-codex", "high")

/// The table the base Routing Table pane is tried on: a catch-all, the authoring entry and three Card entries.
private let table = [
    RoutingEntryDraft(route: sonnet, fallbacks: [codex]),
    RoutingEntryDraft(kind: "authoring", route: opus, fallbacks: [codex]),
    RoutingEntryDraft(kind: "impl", repoRole: "backend", route: opus, fallbacks: [codex, sonnet]),
    RoutingEntryDraft(kind: "impl", route: codex),
    RoutingEntryDraft(kind: "impl.boilerplate", route: route("claude", "haiku", "low"))
]

@Suite("A Routing Entry draft's key")
struct RoutingEntryDraftKeyTests {
    @Test("A blank or * Kind and Repo Role are any")
    func blankIsAny() {
        #expect(RoutingEntryDraft(route: sonnet).isCatchAll)
        #expect(RoutingEntryDraft(kind: "*", repoRole: "*", route: sonnet).isCatchAll)
        #expect(!RoutingEntryDraft(kind: "impl", route: sonnet).isCatchAll)
        #expect(!RoutingEntryDraft(repoRole: "web", route: sonnet).isCatchAll)
    }

    @Test("The key is the Kind and Repo Role the loader would read")
    func keyMatchesTheLoader() throws {
        let entry = RoutingEntryDraft(kind: "impl.boilerplate", repoRole: "web", route: sonnet)
        let expected = RoutingEntry.Key(kind: try kind("impl.boilerplate"), repoRole: .role(RepoRole(rawValue: "web")))
        #expect(entry.key == expected)
        #expect(RoutingEntryDraft(kind: "*", route: sonnet).key == RoutingEntry.Key(kind: .any, repoRole: .any))
    }

    @Test("An invalid Kind has no key and applies to no Card")
    func invalidKindHasNoKey() throws {
        let entries = [RoutingEntryDraft(kind: "impl..x", route: sonnet)]
        #expect(entries[0].key == nil)
        #expect(entries.candidates(kind: try kind("impl"), repoRole: nil).isEmpty)
    }

    @Test("Only the reserved authoring Kind itself is the authoring entry")
    func authoringEntry() {
        #expect(RoutingEntryDraft(kind: "authoring", route: opus).isAuthoringEntry)
        #expect(!RoutingEntryDraft(kind: "authoring.verifier", route: opus).isAuthoringEntry)
        #expect(!RoutingEntryDraft(route: opus).isAuthoringEntry)
    }

    @Test("The chain is the Route then its fallbacks, and writing it splits them again")
    func chainRoundTrips() {
        var entry = RoutingEntryDraft(route: sonnet, fallbacks: [codex])
        #expect(entry.chain == [sonnet, codex])
        entry.chain = [opus, sonnet, codex]
        #expect(entry.route == opus)
        #expect(entry.fallbacks == [sonnet, codex])
    }
}

@Suite("Which entry routes a Card")
struct RoutingEntryDraftCandidatesTests {
    @Test("The longest Kind prefix wins")
    func longestPrefixWins() throws {
        let indices = table.candidates(kind: try kind("impl.boilerplate.css"), repoRole: RepoRole(rawValue: "web"))
        #expect(indices == [4, 3, 0])
    }

    @Test("At equal Kind length, the entry naming the Repo Role beats the one for any")
    func namedRepoRoleWins() throws {
        let indices = table.candidates(kind: try kind("impl.feature"), repoRole: RepoRole(rawValue: "backend"))
        #expect(indices == [2, 3, 0])
    }

    @Test("An entry naming another Repo Role does not apply")
    func otherRepoRoleDoesNotApply() throws {
        let indices = table.candidates(kind: try kind("impl"), repoRole: RepoRole(rawValue: "mobile"))
        #expect(indices == [3, 0])
    }

    @Test("A Card no entry matches has no candidate")
    func noCandidate() throws {
        let entries = [RoutingEntryDraft(kind: "docs", route: sonnet)]
        #expect(entries.candidates(kind: try kind("impl"), repoRole: RepoRole(rawValue: "web")).isEmpty)
    }

    @Test("Between two entries for one key, the earlier wins")
    func earlierDuplicateWins() throws {
        let entries = [RoutingEntryDraft(kind: "impl", route: sonnet), RoutingEntryDraft(kind: "impl", route: opus)]
        #expect(entries.candidates(kind: try kind("impl"), repoRole: nil) == [0, 1])
    }
}

@Suite("Who verifies a Cycle")
struct RoutingEntryDraftVerifierTests {
    @Test("The authoring Kind resolves to the authoring entry ahead of the catch-all")
    func authoringEntryWins() {
        #expect(table.authoringResolution == 1)
    }

    @Test("Without an authoring entry, the authoring Kind resolves to the catch-all")
    func catchAllStandsIn() {
        let entries = table.filter { !$0.isAuthoringEntry }
        #expect(entries.authoringResolution == 0)
        #expect(entries.verifier(excluding: [sonnet]) == codex)
    }

    @Test("An entry naming a Repo Role never resolves the authoring Kind")
    func repoRoleEntryNeverResolvesAuthoring() {
        let entries = [RoutingEntryDraft(repoRole: "backend", route: sonnet)]
        #expect(entries.authoringResolution == nil)
        #expect(entries.verifier(excluding: []) == nil)
    }

    @Test("The verifier is the first Route of the chain that wrote none of the code")
    func firstRouteThatWroteNothing() {
        #expect(table.verifier(excluding: [sonnet]) == opus)
        #expect(table.verifier(excluding: [opus]) == codex)
        #expect(table.verifier(excluding: [opus, sonnet]) == codex)
    }

    @Test("When every Route of the chain wrote the code, nobody verifies it")
    func nobodyVerifies() {
        #expect(table.verifier(excluding: [opus, codex]) == nil)
    }

    @Test("Worker Routes are every complete Route of the Card entries, once each, in table order")
    func workerRoutes() {
        var entries = table
        entries.append(RoutingEntryDraft(kind: "docs", route: route("claude", "", "low")))
        #expect(entries.workerRoutes == [sonnet, codex, opus, route("claude", "haiku", "low")])
    }
}
